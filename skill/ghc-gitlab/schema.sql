-- The SQLite store fetch-gitlab writes, as it creates it.
--
-- This is schema version 1, from src/FetchGitLab/Store/Schema.hs. A store
-- records its version in `meta`; fetch-gitlab refuses one written by a
-- different version rather than read the wrong columns out of it.
--
-- Two ideas run through it.
--
-- Shared objects are interned. The same user object arrives with every note,
-- and a project has thousands of notes per person, so users, milestones and
-- labels live in their own tables and records point at them. `json` rather
-- than the GitLab id is the unique key on those tables, because the same
-- person arrives in different shapes -- a note's author carries fewer fields
-- than a ticket's -- and keying on the id would silently give one of them the
-- other's fields.
--
-- Everything else is kept as JSON, with the columns worth querying GENERATED
-- from it. Modelling ~200 fields as columns would lose whatever was missed
-- from a dump whose whole point is to be faithful; writing the hot columns
-- out beside the JSON made the database half again as large, since every note
-- body was then stored twice. A VIRTUAL generated column takes no space, can
-- be indexed, and cannot drift from the JSON it reads.

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL);

-- Authors, assignees, reviewers, closers, mergers and note authors.
CREATE TABLE IF NOT EXISTS users (
  row_id   INTEGER PRIMARY KEY,
  json     TEXT NOT NULL UNIQUE,
  user_id  INTEGER GENERATED ALWAYS AS (json_extract(json, '$.id')) VIRTUAL,
  username TEXT    GENERATED ALWAYS AS (json_extract(json, '$.username')) VIRTUAL,
  name     TEXT    GENERATED ALWAYS AS (json_extract(json, '$.name')) VIRTUAL);
CREATE INDEX IF NOT EXISTS users_user_id ON users (user_id);
CREATE INDEX IF NOT EXISTS users_username ON users (username);

CREATE TABLE IF NOT EXISTS milestones (
  row_id       INTEGER PRIMARY KEY,
  json         TEXT NOT NULL UNIQUE,
  milestone_id INTEGER GENERATED ALWAYS AS (json_extract(json, '$.id')) VIRTUAL,
  title        TEXT    GENERATED ALWAYS AS (json_extract(json, '$.title')) VIRTUAL);

CREATE TABLE IF NOT EXISTS labels (
  label_id INTEGER PRIMARY KEY,
  name     TEXT NOT NULL UNIQUE);

-- The tickets and merge requests themselves.
--
-- kind is 'ticket' or 'mr'. iid is the project local id -- the number in
-- #25166 and !13000 -- which is what the store is keyed by and what a URL
-- carries; `id` is GitLab's global id and is not the same number.
--
-- `rest` is the record as JSON minus the fields lifted into the tables above:
-- author, assignee, closed_by, merged_by, assignees, reviewers, labels and
-- milestone are NOT in it. `lifted` is the list of keys that were taken out,
-- which is what tells a field that was absent from one that was empty.
--
-- has_discussion and discussion_updated_at are bookkeeping rather than part of
-- the record: whether the notes have ever been fetched, and the record's
-- updated_at when they were, which is how a run knows a discussion has gone
-- stale.
CREATE TABLE IF NOT EXISTS records (
  kind                  TEXT NOT NULL,
  iid                   INTEGER NOT NULL,
  milestone_row         INTEGER REFERENCES milestones(row_id),
  discussion_updated_at TEXT,
  has_discussion        INTEGER NOT NULL,
  rest                  TEXT NOT NULL,
  lifted                TEXT NOT NULL,
  id               INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.id')) VIRTUAL,
  project_id       INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.project_id')) VIRTUAL,
  title            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.title')) VIRTUAL,
  description      TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.description')) VIRTUAL,
  state            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.state')) VIRTUAL,
  created_at       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.created_at')) VIRTUAL,
  updated_at       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.updated_at')) VIRTUAL,
  closed_at        TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.closed_at')) VIRTUAL,
  web_url          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.web_url')) VIRTUAL,
  user_notes_count INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.user_notes_count')) VIRTUAL,
  upvotes          INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.upvotes')) VIRTUAL,
  downvotes        INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.downvotes')) VIRTUAL,
  PRIMARY KEY (kind, iid));
CREATE INDEX IF NOT EXISTS records_updated ON records (kind, updated_at);
CREATE INDEX IF NOT EXISTS records_state ON records (kind, state);

-- A record's people, by the field they appeared in: 'author', 'assignee',
-- 'closed_by' and 'merged_by' hold one user at position 0; 'assignees' and
-- 'reviewers' are ordered lists.
CREATE TABLE IF NOT EXISTS record_users (
  kind     TEXT NOT NULL,
  iid      INTEGER NOT NULL,
  field    TEXT NOT NULL,
  position INTEGER NOT NULL,
  user_row INTEGER NOT NULL REFERENCES users(row_id),
  PRIMARY KEY (kind, iid, field, position));
CREATE INDEX IF NOT EXISTS record_users_rev ON record_users (user_row);

CREATE TABLE IF NOT EXISTS record_labels (
  kind     TEXT NOT NULL,
  iid      INTEGER NOT NULL,
  position INTEGER NOT NULL,
  label_id INTEGER NOT NULL REFERENCES labels(label_id),
  PRIMARY KEY (kind, iid, position));
CREATE INDEX IF NOT EXISTS record_labels_rev ON record_labels (label_id);

-- The discussion of a record, one row per note.
--
-- Keyed by where a note sits in its discussion rather than by GitLab's note
-- id: the id is unique across a real project, but keying on it would make the
-- store depend on that, and a discussion is in any case an ordered list
-- belonging to one record.
--
-- position is the order GitLab returned, which is NEWEST FIRST. Order by
-- created_at for a conversation read top to bottom.
--
-- system = 1 is a note GitLab wrote itself ("assigned to @x", "mentioned in
-- merge request !123") rather than something a person said. There are a lot of
-- them; user_notes_count on the record counts only the human ones.
CREATE TABLE IF NOT EXISTS notes (
  kind          TEXT NOT NULL,
  iid           INTEGER NOT NULL,
  position      INTEGER NOT NULL,
  rest          TEXT NOT NULL,
  lifted        TEXT NOT NULL,
  note_id       INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.id')) VIRTUAL,
  body          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.body')) VIRTUAL,
  created_at    TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.created_at')) VIRTUAL,
  updated_at    TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.updated_at')) VIRTUAL,
  system        INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.system')) VIRTUAL,
  resolvable    INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.resolvable')) VIRTUAL,
  resolved      INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.resolved')) VIRTUAL,
  type          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.type')) VIRTUAL,
  noteable_type TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.noteable_type')) VIRTUAL,
  PRIMARY KEY (kind, iid, position));
CREATE INDEX IF NOT EXISTS notes_id ON notes (note_id);
CREATE INDEX IF NOT EXISTS notes_created ON notes (created_at);

-- A note's people: 'author', and 'resolved_by' where there is one.
CREATE TABLE IF NOT EXISTS note_users (
  kind     TEXT NOT NULL,
  iid      INTEGER NOT NULL,
  position INTEGER NOT NULL,
  field    TEXT NOT NULL,
  user_row INTEGER NOT NULL REFERENCES users(row_id),
  PRIMARY KEY (kind, iid, position, field));
CREATE INDEX IF NOT EXISTS note_users_rev ON note_users (user_row);
