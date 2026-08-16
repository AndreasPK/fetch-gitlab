#!/usr/bin/env bash
#
# Import the JSON lines stores written by fetch-gitlab into a SQLite database.
#
#   tools/jsonl-to-sqlite.sh [--tickets FILE] [--mrs FILE] [--db FILE] [--force]
#
# Needs nothing but sqlite3 (>= 3.38 for the JSON functions used here). The
# JSON is parsed by SQLite itself rather than by jq or a Haskell program, so
# there is no second implementation of the schema to keep in step.
#
# The schema is normalised rather than a JSON column per row: the stores repeat
# the same user objects thousands of times, once per note, and that repetition
# is most of what a database can save. Everything the stores hold is carried
# over, so the import loses nothing.

set -euo pipefail

TICKETS="${HOME}/.fetch-gitlab/tickets.jsonl"
MRS="${HOME}/.fetch-gitlab/mrs.jsonl"
DB="${HOME}/.fetch-gitlab/gitlab.db"
FORCE=no

usage() {
  sed -n '2,16p' "$0" | sed 's/^# \?//'
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tickets) TICKETS="$2"; shift 2 ;;
    --mrs)     MRS="$2";     shift 2 ;;
    --db)      DB="$2";      shift 2 ;;
    --force)   FORCE=yes;    shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown argument: $1" >&2; usage 1 >&2 ;;
  esac
done

command -v sqlite3 >/dev/null || { echo "sqlite3 is not on PATH" >&2; exit 1; }

if [ -e "$DB" ]; then
  if [ "$FORCE" = yes ]; then
    rm -f "$DB" "$DB-journal" "$DB-wal" "$DB-shm"
  else
    echo "$DB already exists; pass --force to replace it" >&2
    exit 1
  fi
fi

for f in "$TICKETS" "$MRS"; do
  [ -e "$f" ] || echo "note: $f does not exist, importing it as empty" >&2
done

SQL="$(mktemp)"
SQL2="$(mktemp)"
trap 'rm -f "$SQL" "$SQL2"' EXIT

# ---------------------------------------------------------------------------
# Schema
#
# Column names follow the JSON field names. The nested objects that appear once
# per record and never repeat -- references, _links, time_stats,
# task_completion_status -- are flattened into columns; the ones that do repeat
# -- users, milestones, labels -- become tables of their own.
# ---------------------------------------------------------------------------
cat > "$SQL" <<'SCHEMA'
.output /dev/null
PRAGMA journal_mode = OFF;
.output stdout
PRAGMA synchronous = OFF;
PRAGMA foreign_keys = ON;

BEGIN;

-- Authors, assignees, reviewers, closers and note authors are all the same
-- shape and mostly the same few hundred people.
CREATE TABLE users (
  id            INTEGER PRIMARY KEY,
  username      TEXT NOT NULL,
  name          TEXT,
  state         TEXT,
  public_email  TEXT,   -- absent on the copies embedded in notes
  avatar_url    TEXT,
  web_url       TEXT
);

CREATE TABLE milestones (
  id           INTEGER PRIMARY KEY,
  iid          INTEGER,
  project_id   INTEGER,
  title        TEXT,
  description  TEXT,
  state        TEXT,
  created_at   TEXT,
  updated_at   TEXT,
  start_date   TEXT,
  due_date     TEXT,
  web_url      TEXT
);

-- The stores hold labels as bare strings; they are given ids here so the
-- junction tables can be narrow.
CREATE TABLE labels (
  id    INTEGER PRIMARY KEY,
  name  TEXT NOT NULL UNIQUE
);

CREATE TABLE tickets (
  iid                    INTEGER PRIMARY KEY,   -- the key the stores use
  id                     INTEGER UNIQUE,        -- GitLab's global id
  project_id             INTEGER,
  title                  TEXT,
  description            TEXT,
  state                  TEXT,
  issue_type             TEXT,
  type                   TEXT,
  confidential           INTEGER,
  created_at             TEXT,
  updated_at             TEXT,
  closed_at              TEXT,
  author_id              INTEGER REFERENCES users(id),
  assignee_id            INTEGER REFERENCES users(id),
  closed_by_id           INTEGER REFERENCES users(id),
  milestone_id           INTEGER REFERENCES milestones(id),
  upvotes                INTEGER,
  downvotes              INTEGER,
  user_notes_count       INTEGER,
  merge_requests_count   INTEGER,
  blocking_issues_count  INTEGER,
  has_tasks              INTEGER,
  task_status            TEXT,
  task_count             INTEGER,
  task_completed_count   INTEGER,
  time_estimate          INTEGER,
  total_time_spent       INTEGER,
  weight                 INTEGER,
  web_url                TEXT,
  ref_short              TEXT,
  ref_relative           TEXT,
  ref_full               TEXT,
  link_self              TEXT,
  link_notes             TEXT,
  link_award_emoji       TEXT,
  link_project           TEXT,
  -- What fetch-gitlab compares against updated_at to decide whether the notes
  -- it has are still current. Without it an import could not be fetched from.
  discussion_updated_at  TEXT,
  has_discussion         INTEGER NOT NULL
);

CREATE TABLE merge_requests (
  iid                           INTEGER PRIMARY KEY,
  id                            INTEGER UNIQUE,
  project_id                    INTEGER,
  title                         TEXT,
  description                   TEXT,
  state                         TEXT,
  created_at                    TEXT,
  updated_at                    TEXT,
  closed_at                     TEXT,
  merged_at                     TEXT,
  author_id                     INTEGER REFERENCES users(id),
  assignee_id                   INTEGER REFERENCES users(id),
  closed_by_id                  INTEGER REFERENCES users(id),
  merged_by_id                  INTEGER REFERENCES users(id),
  milestone_id                  INTEGER REFERENCES milestones(id),
  source_branch                 TEXT,
  target_branch                 TEXT,
  source_project_id             INTEGER,
  target_project_id             INTEGER,
  sha                           TEXT,
  merge_commit_sha              TEXT,
  merge_status                  TEXT,
  draft                         INTEGER,
  work_in_progress              INTEGER,
  squash                        INTEGER,
  has_conflicts                 INTEGER,
  blocking_discussions_resolved INTEGER,
  force_remove_source_branch    INTEGER,
  merge_when_pipeline_succeeds  INTEGER,
  allow_collaboration           INTEGER,
  allow_maintainer_to_push      INTEGER,
  upvotes                       INTEGER,
  downvotes                     INTEGER,
  user_notes_count              INTEGER,
  time_estimate                 INTEGER,
  total_time_spent              INTEGER,
  task_count                    INTEGER,
  task_completed_count          INTEGER,
  web_url                       TEXT,
  reference                     TEXT,
  ref_short                     TEXT,
  ref_relative                  TEXT,
  ref_full                      TEXT,
  discussion_updated_at         TEXT,
  has_discussion                INTEGER NOT NULL
);

CREATE TABLE ticket_labels (
  ticket_iid  INTEGER NOT NULL REFERENCES tickets(iid),
  label_id    INTEGER NOT NULL REFERENCES labels(id),
  PRIMARY KEY (ticket_iid, label_id)
);

CREATE TABLE mr_labels (
  mr_iid    INTEGER NOT NULL REFERENCES merge_requests(iid),
  label_id  INTEGER NOT NULL REFERENCES labels(id),
  PRIMARY KEY (mr_iid, label_id)
);

CREATE TABLE ticket_assignees (
  ticket_iid  INTEGER NOT NULL REFERENCES tickets(iid),
  user_id     INTEGER NOT NULL REFERENCES users(id),
  PRIMARY KEY (ticket_iid, user_id)
);

CREATE TABLE mr_assignees (
  mr_iid   INTEGER NOT NULL REFERENCES merge_requests(iid),
  user_id  INTEGER NOT NULL REFERENCES users(id),
  PRIMARY KEY (mr_iid, user_id)
);

CREATE TABLE mr_reviewers (
  mr_iid   INTEGER NOT NULL REFERENCES merge_requests(iid),
  user_id  INTEGER NOT NULL REFERENCES users(id),
  PRIMARY KEY (mr_iid, user_id)
);

-- One table for both, as GitLab itself keys notes: note ids are global and
-- every note says what it hangs off.
CREATE TABLE notes (
  id              INTEGER PRIMARY KEY,
  noteable_type   TEXT NOT NULL CHECK (noteable_type IN ('Issue', 'MergeRequest')),
  noteable_iid    INTEGER NOT NULL,
  noteable_id     INTEGER,
  author_id       INTEGER REFERENCES users(id),
  body            TEXT,
  created_at      TEXT,
  updated_at      TEXT,
  system          INTEGER,
  confidential    INTEGER,
  resolvable      INTEGER,
  resolved        INTEGER,
  resolved_by_id  INTEGER REFERENCES users(id),
  type            TEXT
);

-- Staging: one row per line of each file, parsed below.
CREATE TABLE raw_tickets (line TEXT);
CREATE TABLE raw_mrs (line TEXT);

COMMIT;
SCHEMA

# ---------------------------------------------------------------------------
# Load the files verbatim.
#
# .mode ascii turns off the CSV quoting rules, which JSON would trip over. The
# field separator is \x01: JSON has to escape every character below \x20, so a
# literal one cannot occur in a valid line and each line arrives as one value.
# ---------------------------------------------------------------------------
{
  echo ".mode ascii"
  echo '.separator "\x01" "\n"'
  [ -e "$TICKETS" ] && printf ".import '%s' raw_tickets\n" "$TICKETS"
  [ -e "$MRS" ]     && printf ".import '%s' raw_mrs\n" "$MRS"
} >> "$SQL"

cat >> "$SQL" <<'IMPORT'
.mode list

-- Blank lines are not records.
DELETE FROM raw_tickets WHERE line IS NULL OR trim(line) = '';
DELETE FROM raw_mrs     WHERE line IS NULL OR trim(line) = '';
IMPORT

sqlite3 "$DB" < "$SQL"

# Refuse a half-parsed import the same way fetch-gitlab refuses a half-parsed
# store: SQLite has no way to raise from a SELECT, so the check lives here.
for tbl in raw_tickets:"$TICKETS" raw_mrs:"$MRS"; do
  bad=$(sqlite3 "$DB" "SELECT group_concat(rowid, ' ') FROM (SELECT rowid FROM ${tbl%%:*} WHERE NOT json_valid(line) LIMIT 5);")
  if [ -n "$bad" ]; then
    echo "${tbl#*:}: not JSON on line(s) $bad" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Normalise
# ---------------------------------------------------------------------------
cat > "$SQL2" <<'IMPORT'
PRAGMA foreign_keys = ON;
BEGIN;

-- The record and its discussion, pulled out once.
CREATE TEMP VIEW t AS
  SELECT json_extract(line, '$.ticket')                AS r,
         coalesce(json_extract(line, '$.discussion'), '[]') AS d,
         json_extract(line, '$.discussion')            IS NOT NULL AS has_d,
         json_extract(line, '$.discussion_updated_at') AS dua
  FROM raw_tickets;

CREATE TEMP VIEW m AS
  SELECT json_extract(line, '$.mr')                    AS r,
         coalesce(json_extract(line, '$.discussion'), '[]') AS d,
         json_extract(line, '$.discussion')            IS NOT NULL AS has_d,
         json_extract(line, '$.discussion_updated_at') AS dua
  FROM raw_mrs;

-- Every place a user object appears, in either file.
CREATE TEMP TABLE user_refs (u TEXT);
INSERT INTO user_refs
      SELECT json_extract(r, '$.author')      FROM t
UNION ALL SELECT json_extract(r, '$.assignee')  FROM t
UNION ALL SELECT json_extract(r, '$.closed_by') FROM t
UNION ALL SELECT j.value FROM t, json_each(coalesce(json_extract(t.r, '$.assignees'), '[]')) j
UNION ALL SELECT json_extract(n.value, '$.author')      FROM t, json_each(t.d) n
UNION ALL SELECT json_extract(n.value, '$.resolved_by') FROM t, json_each(t.d) n
UNION ALL SELECT json_extract(r, '$.author')      FROM m
UNION ALL SELECT json_extract(r, '$.assignee')  FROM m
UNION ALL SELECT json_extract(r, '$.closed_by') FROM m
UNION ALL SELECT json_extract(r, '$.merged_by') FROM m
UNION ALL SELECT j.value FROM m, json_each(coalesce(json_extract(m.r, '$.assignees'), '[]')) j
UNION ALL SELECT j.value FROM m, json_each(coalesce(json_extract(m.r, '$.reviewers'), '[]')) j
UNION ALL SELECT json_extract(n.value, '$.author')      FROM m, json_each(m.d) n
UNION ALL SELECT json_extract(n.value, '$.resolved_by') FROM m, json_each(m.d) n;
DELETE FROM user_refs WHERE u IS NULL;

-- max() skips nulls, so a field carried by only some copies of a user -- which
-- is what public_email is -- survives into the row.
INSERT INTO users (id, username, name, state, public_email, avatar_url, web_url)
SELECT json_extract(u, '$.id'),
       max(json_extract(u, '$.username')),
       max(json_extract(u, '$.name')),
       max(json_extract(u, '$.state')),
       max(json_extract(u, '$.public_email')),
       max(json_extract(u, '$.avatar_url')),
       max(json_extract(u, '$.web_url'))
FROM user_refs
GROUP BY json_extract(u, '$.id');

CREATE TEMP TABLE milestone_refs (ms TEXT);
INSERT INTO milestone_refs
      SELECT json_extract(r, '$.milestone') FROM t
UNION ALL SELECT json_extract(r, '$.milestone') FROM m;
DELETE FROM milestone_refs WHERE ms IS NULL;

INSERT INTO milestones (id, iid, project_id, title, description, state,
                        created_at, updated_at, start_date, due_date, web_url)
SELECT json_extract(ms, '$.id'),
       max(json_extract(ms, '$.iid')),
       max(json_extract(ms, '$.project_id')),
       max(json_extract(ms, '$.title')),
       max(json_extract(ms, '$.description')),
       max(json_extract(ms, '$.state')),
       max(json_extract(ms, '$.created_at')),
       max(json_extract(ms, '$.updated_at')),
       max(json_extract(ms, '$.start_date')),
       max(json_extract(ms, '$.due_date')),
       max(json_extract(ms, '$.web_url'))
FROM milestone_refs
GROUP BY json_extract(ms, '$.id');

INSERT INTO labels (name)
SELECT DISTINCT value FROM (
      SELECT j.value FROM t, json_each(coalesce(json_extract(t.r, '$.labels'), '[]')) j
  UNION SELECT j.value FROM m, json_each(coalesce(json_extract(m.r, '$.labels'), '[]')) j
);

INSERT INTO tickets
SELECT json_extract(r, '$.iid'),
       json_extract(r, '$.id'),
       json_extract(r, '$.project_id'),
       json_extract(r, '$.title'),
       json_extract(r, '$.description'),
       json_extract(r, '$.state'),
       json_extract(r, '$.issue_type'),
       json_extract(r, '$.type'),
       json_extract(r, '$.confidential'),
       json_extract(r, '$.created_at'),
       json_extract(r, '$.updated_at'),
       json_extract(r, '$.closed_at'),
       json_extract(r, '$.author.id'),
       json_extract(r, '$.assignee.id'),
       json_extract(r, '$.closed_by.id'),
       json_extract(r, '$.milestone.id'),
       json_extract(r, '$.upvotes'),
       json_extract(r, '$.downvotes'),
       json_extract(r, '$.user_notes_count'),
       json_extract(r, '$.merge_requests_count'),
       json_extract(r, '$.blocking_issues_count'),
       json_extract(r, '$.has_tasks'),
       json_extract(r, '$.task_status'),
       json_extract(r, '$.task_completion_status.count'),
       json_extract(r, '$.task_completion_status.completed_count'),
       json_extract(r, '$.time_stats.time_estimate'),
       json_extract(r, '$.time_stats.total_time_spent'),
       json_extract(r, '$.weight'),
       json_extract(r, '$.web_url'),
       json_extract(r, '$.references.short'),
       json_extract(r, '$.references.relative'),
       json_extract(r, '$.references.full'),
       json_extract(r, '$._links.self'),
       json_extract(r, '$._links.notes'),
       json_extract(r, '$._links.award_emoji'),
       json_extract(r, '$._links.project'),
       dua,
       has_d
FROM t;

INSERT INTO merge_requests
SELECT json_extract(r, '$.iid'),
       json_extract(r, '$.id'),
       json_extract(r, '$.project_id'),
       json_extract(r, '$.title'),
       json_extract(r, '$.description'),
       json_extract(r, '$.state'),
       json_extract(r, '$.created_at'),
       json_extract(r, '$.updated_at'),
       json_extract(r, '$.closed_at'),
       json_extract(r, '$.merged_at'),
       json_extract(r, '$.author.id'),
       json_extract(r, '$.assignee.id'),
       json_extract(r, '$.closed_by.id'),
       json_extract(r, '$.merged_by.id'),
       json_extract(r, '$.milestone.id'),
       json_extract(r, '$.source_branch'),
       json_extract(r, '$.target_branch'),
       json_extract(r, '$.source_project_id'),
       json_extract(r, '$.target_project_id'),
       json_extract(r, '$.sha'),
       json_extract(r, '$.merge_commit_sha'),
       json_extract(r, '$.merge_status'),
       json_extract(r, '$.draft'),
       json_extract(r, '$.work_in_progress'),
       json_extract(r, '$.squash'),
       json_extract(r, '$.has_conflicts'),
       json_extract(r, '$.blocking_discussions_resolved'),
       json_extract(r, '$.force_remove_source_branch'),
       json_extract(r, '$.merge_when_pipeline_succeeds'),
       json_extract(r, '$.allow_collaboration'),
       json_extract(r, '$.allow_maintainer_to_push'),
       json_extract(r, '$.upvotes'),
       json_extract(r, '$.downvotes'),
       json_extract(r, '$.user_notes_count'),
       json_extract(r, '$.time_stats.time_estimate'),
       json_extract(r, '$.time_stats.total_time_spent'),
       json_extract(r, '$.task_completion_status.count'),
       json_extract(r, '$.task_completion_status.completed_count'),
       json_extract(r, '$.web_url'),
       json_extract(r, '$.reference'),
       json_extract(r, '$.references.short'),
       json_extract(r, '$.references.relative'),
       json_extract(r, '$.references.full'),
       dua,
       has_d
FROM m;

INSERT INTO ticket_labels
SELECT DISTINCT json_extract(t.r, '$.iid'), l.id
FROM t, json_each(coalesce(json_extract(t.r, '$.labels'), '[]')) j
JOIN labels l ON l.name = j.value;

INSERT INTO mr_labels
SELECT DISTINCT json_extract(m.r, '$.iid'), l.id
FROM m, json_each(coalesce(json_extract(m.r, '$.labels'), '[]')) j
JOIN labels l ON l.name = j.value;

INSERT INTO ticket_assignees
SELECT DISTINCT json_extract(t.r, '$.iid'), json_extract(j.value, '$.id')
FROM t, json_each(coalesce(json_extract(t.r, '$.assignees'), '[]')) j;

INSERT INTO mr_assignees
SELECT DISTINCT json_extract(m.r, '$.iid'), json_extract(j.value, '$.id')
FROM m, json_each(coalesce(json_extract(m.r, '$.assignees'), '[]')) j;

INSERT INTO mr_reviewers
SELECT DISTINCT json_extract(m.r, '$.iid'), json_extract(j.value, '$.id')
FROM m, json_each(coalesce(json_extract(m.r, '$.reviewers'), '[]')) j;

INSERT INTO notes
SELECT json_extract(n.value, '$.id'),
       coalesce(json_extract(n.value, '$.noteable_type'), 'Issue'),
       json_extract(t.r, '$.iid'),
       json_extract(n.value, '$.noteable_id'),
       json_extract(n.value, '$.author.id'),
       json_extract(n.value, '$.body'),
       json_extract(n.value, '$.created_at'),
       json_extract(n.value, '$.updated_at'),
       json_extract(n.value, '$.system'),
       json_extract(n.value, '$.confidential'),
       json_extract(n.value, '$.resolvable'),
       json_extract(n.value, '$.resolved'),
       json_extract(n.value, '$.resolved_by.id'),
       json_extract(n.value, '$.type')
FROM t, json_each(t.d) n;

INSERT INTO notes
SELECT json_extract(n.value, '$.id'),
       coalesce(json_extract(n.value, '$.noteable_type'), 'MergeRequest'),
       json_extract(m.r, '$.iid'),
       json_extract(n.value, '$.noteable_id'),
       json_extract(n.value, '$.author.id'),
       json_extract(n.value, '$.body'),
       json_extract(n.value, '$.created_at'),
       json_extract(n.value, '$.updated_at'),
       json_extract(n.value, '$.system'),
       json_extract(n.value, '$.confidential'),
       json_extract(n.value, '$.resolvable'),
       json_extract(n.value, '$.resolved'),
       json_extract(n.value, '$.resolved_by.id'),
       json_extract(n.value, '$.type')
FROM m, json_each(m.d) n;

DROP TABLE raw_tickets;
DROP TABLE raw_mrs;

COMMIT;

-- Built after the load rather than maintained during it.
CREATE INDEX notes_noteable    ON notes (noteable_type, noteable_iid);
CREATE INDEX notes_author      ON notes (author_id);
CREATE INDEX notes_created     ON notes (created_at);
CREATE INDEX tickets_updated   ON tickets (updated_at);
CREATE INDEX tickets_state     ON tickets (state);
CREATE INDEX tickets_author    ON tickets (author_id);
CREATE INDEX mrs_updated       ON merge_requests (updated_at);
CREATE INDEX mrs_state         ON merge_requests (state);
CREATE INDEX mrs_author        ON merge_requests (author_id);
CREATE INDEX ticket_labels_rev ON ticket_labels (label_id);
CREATE INDEX mr_labels_rev     ON mr_labels (label_id);

ANALYZE;
VACUUM;

-- Nothing should be pointing at a row that is not there.
PRAGMA foreign_key_check;
IMPORT

sqlite3 "$DB" < "$SQL2"

echo "wrote $DB"
sqlite3 "$DB" <<'REPORT'
.mode list
.separator " "
SELECT 'tickets       ', count(*) FROM tickets
UNION ALL SELECT 'merge_requests', count(*) FROM merge_requests
UNION ALL SELECT 'notes         ', count(*) FROM notes
UNION ALL SELECT 'users         ', count(*) FROM users
UNION ALL SELECT 'labels        ', count(*) FROM labels
UNION ALL SELECT 'milestones    ', count(*) FROM milestones;
REPORT
