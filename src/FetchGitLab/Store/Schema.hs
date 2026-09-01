{-# LANGUAGE OverloadedStrings #-}

-- | The relational shape of what a store holds.
--
-- What GitLab sends repeats itself heavily: the same user object arrives once
-- per note, and a project's notes outnumber its people by thousands to one.
-- This module says what the objects actually are and how they relate, so a
-- backend that can share them does not have to guess.
--
-- The entities are:
--
-- * __users__ — authors, assignees, reviewers, closers and note authors, all
--   the same shape and mostly the same few hundred people.
-- * __milestones__ — inlined into every record that belongs to one.
-- * __labels__ — bare strings in the JSON, shared by many records.
-- * __records__ — the tickets and merge requests themselves.
-- * __notes__ — the discussion of a record, one row each.
--
-- and the relations:
--
-- * a record refers to users through named fields ('specUsers') and through
--   ordered lists ('specUserLists'),
-- * a record has an ordered list of labels and at most one milestone,
-- * a note belongs to exactly one record and refers to users of its own.
--
-- == What is stored, and why it is still exact
--
-- Modelling every field of @gitlab-haskell@'s 'GitLab.Types.Issue' and
-- 'GitLab.Types.MergeRequest' as a column would mean some two hundred columns,
-- nested @Pipeline@ and @Epic@ objects included, and any field missed would be
-- lost from a dump whose whole purpose is to be faithful. So a record is split
-- rather than dissected: the shared sub-objects above are lifted out into
-- their own tables, the frequently queried scalars are copied into columns,
-- and whatever is left over is kept verbatim as JSON.
--
-- 'splitObject' and 'spliceObject' (in "FetchGitLab.Store.Schema.Types",
-- re-exported here) are inverses, which is what makes that safe: what comes
-- back out of a store is the value that went in, not a best effort at
-- reassembling one.
module FetchGitLab.Store.Schema
  ( -- * Lifting shared objects out of a record
    LiftSpec (..)
  , recordSpec
  , noteSpec
  , Lifted (..)
  , noLifted
  , splitObject
  , spliceObject

    -- * The tables themselves
  , schemaStatements
  , schemaVersion
  , compatibleVersions
  ) where

import Data.Text (Text)

import FetchGitLab.Store.Schema.Pipeline (pipelineSchemaStatements)
import FetchGitLab.Store.Schema.Types

-- | Bumped whenever 'schemaStatements' changes shape. A store written by a
-- version not in 'compatibleVersions' is not read, since the reader would
-- quietly see the wrong columns.
--
-- Version 2 added the pipeline and job tables of
-- "FetchGitLab.Store.Schema.Pipeline".
schemaVersion :: Int
schemaVersion = 2

-- | Older versions whose stores this code still reads correctly, because
-- everything since only added tables — opening such a store creates the
-- missing tables and changes nothing it already holds. The recorded version
-- is deliberately left as it was, so a binary of that older version can
-- still open the store as well.
compatibleVersions :: [Int]
compatibleVersions = [1]

-- | What is lifted out of a ticket or merge request.
recordSpec :: LiftSpec
recordSpec =
  LiftSpec
    { specUsers = ["author", "assignee", "closed_by", "merged_by"]
    , specUserLists = ["assignees", "reviewers"]
    , specMilestone = True
    , specLabels = True
    }

-- | What is lifted out of a note. Notes carry the bulk of a store, and every
-- one of them carries a copy of its author.
noteSpec :: LiftSpec
noteSpec =
  LiftSpec
    { specUsers = ["author", "resolved_by"]
    , specUserLists = []
    , specMilestone = False
    , specLabels = False
    }

-- | The tables, in an order that can be executed as given.
--
-- == Generated columns
--
-- The columns worth querying — a title, a state, a note's body — are
-- @GENERATED ... VIRTUAL@ from the JSON they already live in rather than
-- written beside it. They take no space, they can be indexed, and there is no
-- Haskell code deciding what goes in them, so they cannot come to disagree
-- with the record they describe. Writing them as ordinary columns was the
-- first attempt and made the database half again as large as the JSON it
-- holds, since every note body was then stored twice.
--
-- The real columns are only what SQLite cannot derive: the keys, the lifted
-- references, and the two pieces of bookkeeping that are not part of a record
-- at all — whether its discussion has been fetched, and the @updated_at@ it
-- was fetched for.
--
-- == Sharing
--
-- @json@ is unique on the shared tables rather than the GitLab id, because the
-- same person arrives in different shapes: a note's author carries fewer
-- fields than a ticket's does. Keying on the id would silently give one of
-- them the other's fields, so identical objects are shared and differing ones
-- are kept apart.
schemaStatements :: [Text]
schemaStatements =
  [ "CREATE TABLE IF NOT EXISTS meta (\
    \  key   TEXT PRIMARY KEY,\
    \  value TEXT NOT NULL)"
  , "CREATE TABLE IF NOT EXISTS users (\
    \  row_id   INTEGER PRIMARY KEY,\
    \  json     TEXT NOT NULL UNIQUE,\
    \  user_id  INTEGER GENERATED ALWAYS AS (json_extract(json, '$.id')) VIRTUAL,\
    \  username TEXT    GENERATED ALWAYS AS (json_extract(json, '$.username')) VIRTUAL,\
    \  name     TEXT    GENERATED ALWAYS AS (json_extract(json, '$.name')) VIRTUAL)"
  , "CREATE INDEX IF NOT EXISTS users_user_id ON users (user_id)"
  , "CREATE INDEX IF NOT EXISTS users_username ON users (username)"
  , "CREATE TABLE IF NOT EXISTS milestones (\
    \  row_id       INTEGER PRIMARY KEY,\
    \  json         TEXT NOT NULL UNIQUE,\
    \  milestone_id INTEGER GENERATED ALWAYS AS (json_extract(json, '$.id')) VIRTUAL,\
    \  title        TEXT    GENERATED ALWAYS AS (json_extract(json, '$.title')) VIRTUAL)"
  , "CREATE TABLE IF NOT EXISTS labels (\
    \  label_id INTEGER PRIMARY KEY,\
    \  name     TEXT NOT NULL UNIQUE)"
  , -- kind is 'ticket' or 'mr'; iid is the project local id the stores key on.
    "CREATE TABLE IF NOT EXISTS records (\
    \  kind                  TEXT NOT NULL,\
    \  iid                   INTEGER NOT NULL,\
    \  milestone_row         INTEGER REFERENCES milestones(row_id),\
    \  discussion_updated_at TEXT,\
    \  has_discussion        INTEGER NOT NULL,\
    \  rest                  TEXT NOT NULL,\
    \  lifted                TEXT NOT NULL,\
    \  id               INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.id')) VIRTUAL,\
    \  project_id       INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.project_id')) VIRTUAL,\
    \  title            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.title')) VIRTUAL,\
    \  description      TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.description')) VIRTUAL,\
    \  state            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.state')) VIRTUAL,\
    \  created_at       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.created_at')) VIRTUAL,\
    \  updated_at       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.updated_at')) VIRTUAL,\
    \  closed_at        TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.closed_at')) VIRTUAL,\
    \  web_url          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.web_url')) VIRTUAL,\
    \  user_notes_count INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.user_notes_count')) VIRTUAL,\
    \  upvotes          INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.upvotes')) VIRTUAL,\
    \  downvotes        INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.downvotes')) VIRTUAL,\
    \  PRIMARY KEY (kind, iid))"
  , "CREATE INDEX IF NOT EXISTS records_updated ON records (kind, updated_at)"
  , "CREATE INDEX IF NOT EXISTS records_state ON records (kind, state)"
  , "CREATE TABLE IF NOT EXISTS record_users (\
    \  kind     TEXT NOT NULL,\
    \  iid      INTEGER NOT NULL,\
    \  field    TEXT NOT NULL,\
    \  position INTEGER NOT NULL,\
    \  user_row INTEGER NOT NULL REFERENCES users(row_id),\
    \  PRIMARY KEY (kind, iid, field, position))"
  , "CREATE INDEX IF NOT EXISTS record_users_rev ON record_users (user_row)"
  , "CREATE TABLE IF NOT EXISTS record_labels (\
    \  kind     TEXT NOT NULL,\
    \  iid      INTEGER NOT NULL,\
    \  position INTEGER NOT NULL,\
    \  label_id INTEGER NOT NULL REFERENCES labels(label_id),\
    \  PRIMARY KEY (kind, iid, position))"
  , "CREATE INDEX IF NOT EXISTS record_labels_rev ON record_labels (label_id)"
  , -- A note is keyed by where it sits in a discussion, not by GitLab's note
    -- id. The id is unique across a real project, but keying on it would make
    -- the store depend on that being true, and a discussion is in any case an
    -- ordered list belonging to one record. position is what keeps the order.
    "CREATE TABLE IF NOT EXISTS notes (\
    \  kind          TEXT NOT NULL,\
    \  iid           INTEGER NOT NULL,\
    \  position      INTEGER NOT NULL,\
    \  rest          TEXT NOT NULL,\
    \  lifted        TEXT NOT NULL,\
    \  note_id       INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.id')) VIRTUAL,\
    \  body          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.body')) VIRTUAL,\
    \  created_at    TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.created_at')) VIRTUAL,\
    \  updated_at    TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.updated_at')) VIRTUAL,\
    \  system        INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.system')) VIRTUAL,\
    \  resolvable    INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.resolvable')) VIRTUAL,\
    \  resolved      INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.resolved')) VIRTUAL,\
    \  type          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.type')) VIRTUAL,\
    \  noteable_type TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.noteable_type')) VIRTUAL,\
    \  PRIMARY KEY (kind, iid, position))"
  , "CREATE INDEX IF NOT EXISTS notes_id ON notes (note_id)"
  , "CREATE INDEX IF NOT EXISTS notes_created ON notes (created_at)"
  , "CREATE TABLE IF NOT EXISTS note_users (\
    \  kind     TEXT NOT NULL,\
    \  iid      INTEGER NOT NULL,\
    \  position INTEGER NOT NULL,\
    \  field    TEXT NOT NULL,\
    \  user_row INTEGER NOT NULL REFERENCES users(row_id),\
    \  PRIMARY KEY (kind, iid, position, field))"
  , "CREATE INDEX IF NOT EXISTS note_users_rev ON note_users (user_row)"
  ]
    -- Appended last: the jobs table references users, which must exist first.
    <> pipelineSchemaStatements
