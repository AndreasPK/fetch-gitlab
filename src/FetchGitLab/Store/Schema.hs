{-# LANGUAGE OverloadedStrings #-}

{- | The relational shape of what a store holds.

What GitLab sends repeats itself heavily: the same user object arrives once
per note, and a project's notes outnumber its people by thousands to one.
This module says what the objects actually are and how they relate, so a
backend that can share them does not have to guess.

The entities are:

* __users__ — authors, assignees, reviewers, closers and note authors, all
  the same shape and mostly the same few hundred people.
* __milestones__ — inlined into every record that belongs to one.
* __labels__ — bare strings in the JSON, shared by many records.
* __records__ — the tickets and merge requests themselves.
* __notes__ — the discussion of a record, one row each.

and the relations:

* a record refers to users through named fields ('specUsers') and through
  ordered lists ('specUserLists'),
* a record has an ordered list of labels and at most one milestone,
* a note belongs to exactly one record and refers to users of its own.

== What is stored, and why it is still exact

Modelling every field of @gitlab-haskell@'s 'GitLab.Types.Issue' and
'GitLab.Types.MergeRequest' as a column would mean some two hundred columns,
nested @Pipeline@ and @Epic@ objects included, and any field missed would be
lost from a dump whose whole purpose is to be faithful. So a record is split
rather than dissected: the shared sub-objects above are lifted out into
their own tables, the frequently queried scalars are copied into columns,
and whatever is left over is kept verbatim as JSON.

'splitObject' and 'spliceObject' (in "FetchGitLab.Store.Schema.Types",
re-exported here) are inverses, which is what makes that safe: what comes
back out of a store is the value that went in, not a best effort at
reassembling one.
-}
module FetchGitLab.Store.Schema (
    -- * Lifting shared objects out of a record
    LiftSpec (..),
    recordSpec,
    noteSpec,
    Lifted (..),
    noLifted,
    splitObject,
    spliceObject,

    -- * The tables themselves
    schemaStatements,
    schemaVersion,

    -- * Additions since
    SchemaPatch (..),
    schemaPatchVersion,
    schemaPatches,
) where

import Data.Text (Text)

import FetchGitLab.Store.Schema.Pipeline (jobLogAndExpiryStatements, pipelineSchemaStatements)
import FetchGitLab.Store.Schema.Types
import FetchGitLab.Store.Schema.Views (ciViewStatements, viewStatements)

{- | Bumped when the schema changes in ways that would break older executables.
Small (compatible) additions are done by patches.
-}
schemaVersion :: Int
schemaVersion = 1

{- | Number of patches on top of the base schema this executable applies and
expects.
-}
schemaPatchVersion :: Int
schemaPatchVersion = length schemaPatches

{- | One step of the schema's history: the statements that take a store one
patch level on, and what makes them apply.
-}
data SchemaPatch = SchemaPatch
    { patchStatements :: [Text]
    -- ^ Executed in the order given.
    , patchGuard :: Maybe Text
    {- ^ A query run first; the statements run only if it returns a row.
    'Nothing' for a patch that applies to every store, which is every patch
    whose statements are @IF NOT EXISTS@ or otherwise repeatable. A guard is
    what lets a patch that undoes part of the base schema exist at all: a
    store created today never had the thing to undo, and unguarded @ALTER
    TABLE ... DROP COLUMN@ would fail on it.
    -}
    }

{- | Everything added to the schema after the base schema ('schemaStatements').
If we find a store at patch version n, we apply the `drop n schemaPatches`
patches.

A patch is appended, never edited: a store may already have run it.

Patches:

* 1. Add the pipeline, job, runner and commit tables. Happens to be
  idempotent.
* 2. Drop @records.has_discussion@, which "fetched" is now read off
  @discussion_updated_at IS NOT NULL@ instead. Guarded, since a store
  created after the column was removed never had it.
* 3. Add the generated @ref@ column and its index to @records@ and
  @notes@, and drop the @notes_id@ index ('refStatements'). Unguarded:
  @ADD COLUMN@ cannot be repeated, but the column is not in the base
  schema, so every store runs this exactly once.
* 4. The views for querying by hand ('viewStatements' in
  "FetchGitLab.Store.Schema.Views"). @IF NOT EXISTS@, so repeatable. A
  view is frozen in the store: changing one is a later patch that drops
  and recreates it, and a column a view mentions cannot be dropped until
  the view is.
* 5. The @job_logs@ table with the trigger that deletes a log with its
  job, and @expire_at@ on @pipelines@ and @jobs@ with a retention period
  for the rows a store already holds ('jobLogAndExpiryStatements' in
  "FetchGitLab.Store.Schema.Pipeline"). Unguarded: @ADD COLUMN@ cannot be
  repeated, but the column is in neither the base schema nor patch 1, so
  every store runs this exactly once. Then the views over pipelines and
  jobs ('ciViewStatements'), last because they read @job_logs@ and
  @expire_at@.

A patch that adds an index ends with @ANALYZE@. Without planner statistics
SQLite rates an equality on the leading primary key column as cheap and
walks half a table on @kind = 'ticket'@ rather than using the new index.

Patch 2 is the first that an older executable could not read a patched store
with, which the rule above says should be a 'schemaVersion' bump instead.
It is not one because bumping refuses every store that exists rather than
migrating it, and the only readers are this binary and SQL that a patched
store answers as well as it ever did; see log 2026-09-03 "write-through
store".
-}
schemaPatches :: [SchemaPatch]
schemaPatches =
    [ SchemaPatch pipelineSchemaStatements Nothing
    , SchemaPatch
        ["ALTER TABLE records DROP COLUMN has_discussion"]
        (Just "SELECT 1 FROM pragma_table_info('records') WHERE name = 'has_discussion'")
    , SchemaPatch refStatements Nothing
    , SchemaPatch viewStatements Nothing
    , SchemaPatch (jobLogAndExpiryStatements <> ciViewStatements) Nothing
    ]

{- | A row's own name in GitLab notation: @#123@ for a ticket, @!123@ for a
merge request, and on a note the record it sits on. Not a link and not a
key: the tables are still keyed by @(kind, iid)@, and the junction and
pipeline tables join on that. It exists so that a query can say
@WHERE ref = '#123'@ and hit an index; the same expression inside a view is
not indexable and scans.

Generated and virtual, like the other queryable columns, so it takes no
space and cannot disagree with the row it names.

The same patch drops @notes_id@, the index on a note's GitLab id. Notes
are keyed by their position in a discussion (see the @notes@ table), so
nothing in the binary or the documented queries ever looks a note up by
id, and the index cost 8 MB on the real store for nothing. The base schema
no longer creates it, so a fresh store has nothing to drop; the statement
is @IF EXISTS@ for that reason.
-}
refStatements :: [Text]
refStatements =
    [ "ALTER TABLE records ADD COLUMN ref TEXT GENERATED ALWAYS AS \
      \(CASE kind WHEN 'ticket' THEN '#' ELSE '!' END || iid) VIRTUAL"
    , "ALTER TABLE notes ADD COLUMN ref TEXT GENERATED ALWAYS AS \
      \(CASE kind WHEN 'ticket' THEN '#' ELSE '!' END || iid) VIRTUAL"
    , "CREATE INDEX IF NOT EXISTS records_ref ON records (ref)"
    , "CREATE INDEX IF NOT EXISTS notes_ref ON notes (ref, position)"
    , "DROP INDEX IF EXISTS notes_id"
    , "ANALYZE"
    ]

-- | What is lifted out of a ticket or merge request.
recordSpec :: LiftSpec
recordSpec =
    LiftSpec
        { specUsers = ["author", "assignee", "closed_by", "merged_by"]
        , specUserLists = ["assignees", "reviewers"]
        , specMilestone = True
        , specLabels = True
        }

{- | What is lifted out of a note. Notes carry the bulk of a store, and every
one of them carries a copy of its author.
-}
noteSpec :: LiftSpec
noteSpec =
    LiftSpec
        { specUsers = ["author", "resolved_by"]
        , specUserLists = []
        , specMilestone = False
        , specLabels = False
        }

{- | The tables, in an order that can be executed as given.

== Generated columns

The columns worth querying — a title, a state, a note's body — are
@GENERATED ... VIRTUAL@ from the JSON they already live in rather than
written beside it. They take no space, they can be indexed, and there is no
Haskell code deciding what goes in them, so they cannot come to disagree
with the record they describe. Writing them as ordinary columns was the
first attempt and made the database half again as large as the JSON it
holds, since every note body was then stored twice.

The real columns are only what SQLite cannot derive: the keys, the lifted
references, and the one piece of bookkeeping that is not part of a record at
all — @discussion_updated_at@, the record's @updated_at@ at the time its
notes were fetched. NULL says the notes were never fetched, or that
@--clear-timestamp@ dropped the claim that they are current; both mean the
same thing to a run, which is "fetch them". A discussion that was fetched
and turned out to be empty is therefore indistinguishable from one never
fetched once its stamp is cleared, and that costs one request to find out
again.

@discussion_updated_at@ is compared against the generated
@updated_at@ to decide whether a discussion is stale, so the two must be
written by the same timestamp encoder. Today both go through aeson, which
trims the fraction; see @encodeTime@ in "FetchGitLab.Store.Sqlite" for what
that requires of any new write path, and for why the text does not sort
chronologically.

== Sharing

@json@ is unique on the shared tables rather than the GitLab id, because the
same person arrives in different shapes: a note's author carries fewer
fields than a ticket's does. Keying on the id would silently give one of
them the other's fields, so identical objects are shared and differing ones
are kept apart.
-}
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
