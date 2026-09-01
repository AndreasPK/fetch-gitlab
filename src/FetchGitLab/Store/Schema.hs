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
-- 'splitObject' and 'spliceObject' are inverses, which is what makes that
-- safe: what comes back out of a store is the value that went in, not a
-- best effort at reassembling one.
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
  ) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Vector as V

-- | Bumped whenever 'schemaStatements' changes shape. A store written by a
-- different version is not read, since the reader would quietly see the wrong
-- columns.
schemaVersion :: Int
schemaVersion = 1

-- | Which of an object's fields are shared with other objects, and so belong
-- in a table of their own rather than in the object.
data LiftSpec = LiftSpec
  { specUsers :: [Text]
    -- ^ Fields holding a single user.
  , specUserLists :: [Text]
    -- ^ Fields holding an ordered list of users.
  , specMilestone :: Bool
    -- ^ Whether a @milestone@ field is lifted.
  , specLabels :: Bool
    -- ^ Whether a @labels@ field is lifted.
  }

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

-- | The shared objects taken out of one record or note.
data Lifted = Lifted
  { liftedUsers :: [(Text, Int, Value)]
    -- ^ Field name, position within it, and the user. A field in 'specUsers'
    -- contributes one entry at position 0.
  , liftedMilestone :: Maybe Value
  , liftedLabels :: [(Int, Text)]
    -- ^ Position and name, since the order in the JSON is worth keeping.
  , liftedKeys :: [Text]
    -- ^ The keys actually removed, in the order 'spliceObject' should put
    -- them back. This is what tells an absent field from an empty one: a
    -- record with no assignees at all and one with @[]@ differ only here.
  }
  deriving (Eq, Show)

noLifted :: Lifted
noLifted = Lifted [] Nothing [] []

-- | Take the shared objects out of a JSON object.
--
-- Returns what is left and what was removed. Fields the object does not have
-- are not invented, and a field holding @null@ is left where it is rather than
-- lifted, so that splicing puts back exactly what was there.
splitObject :: LiftSpec -> Value -> (Value, Lifted)
splitObject spec (Object o) = (Object leftover, lifted)
  where
    leftover = foldr (KM.delete . Key.fromText) o (liftedKeys lifted)

    lifted =
      Lifted
        { liftedUsers = singles <> lists
        , liftedMilestone = milestone
        , liftedLabels = labels
        , liftedKeys = keys
        }

    -- A key is only lifted if it holds something of the shape we expect.
    at k = KM.lookup (Key.fromText k) o

    singles =
      [ (k, 0, v)
      | k <- specUsers spec
      , Just v@(Object _) <- [at k]
      ]

    lists =
      [ (k, i, v)
      | k <- specUserLists spec
      , Just (Array xs) <- [at k]
      , (i, v) <- zip [0 ..] (V.toList xs)
      ]

    milestone
      | specMilestone spec, Just v@(Object _) <- at "milestone" = Just v
      | otherwise = Nothing

    labels
      | specLabels spec
      , Just (Array xs) <- at "labels" =
          [(i, t) | (i, String t) <- zip [0 ..] (V.toList xs)]
      | otherwise = []

    keys =
      [k | (k, _, _) <- singles]
        <> [k | k <- specUserLists spec, Just (Array _) <- [at k]]
        <> ["milestone" | Just _ <- [milestone]]
        <> ["labels" | specLabels spec, Just (Array _) <- [at "labels"]]
splitObject _ v = (v, noLifted)

-- | Put back what 'splitObject' took out.
--
-- @'spliceObject' spec l . fst . 'splitObject' spec@ is the identity on any
-- object @splitObject@ produced @l@ from.
spliceObject :: LiftSpec -> Lifted -> Value -> Value
spliceObject spec l (Object o) = Object (foldl put o (liftedKeys l))
  where
    put acc k = case rebuild k of
      Nothing -> acc
      Just v -> KM.insert (Key.fromText k) v acc

    rebuild k
      | k `elem` specUsers spec =
          case [v | (f, _, v) <- liftedUsers l, f == k] of
            (v : _) -> Just v
            [] -> Nothing
      | k `elem` specUserLists spec =
          Just . Array . V.fromList . map snd . sortOn fst $
            [(i, v) | (f, i, v) <- liftedUsers l, f == k]
      | k == "milestone" = liftedMilestone l
      | k == "labels" =
          Just . Array . V.fromList . map (String . snd) . sortOn fst $ liftedLabels l
      | otherwise = Nothing
spliceObject _ _ v = v

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
