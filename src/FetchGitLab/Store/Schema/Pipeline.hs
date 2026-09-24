{-# LANGUAGE OverloadedStrings #-}

-- == Expiry
--
-- A pipeline, a job and a log each carry @expire_at@. Which causes us to clean
-- those up to avoid storing megabytes of logs forever.

{- | The relational shape of a merge request's pipelines and their jobs.

== Pipelines

@GET \/projects\/:id\/merge_requests\/:iid\/pipelines@ returns the /basic/
pipeline object: @id@, @iid@, @project_id@, @status@, @source@, @ref@,
@sha@, @name@, @web_url@, @created_at@ and @updated_at@ — no user, no
durations, no nested objects. So unlike a record there is nothing worth
lifting out of one; the object is kept verbatim and the fields the docs
promise are generated columns over it, as in "FetchGitLab.Store.Schema".

A pipeline is keyed by its project-unique @id@. Which merge request it was
fetched for is not part of the object, so the store has to remember it:
@kind@ and @iid@ name the owning record, exactly as the discussion tables
do. @iid@ is the merge request's iid — the pipeline's own project-local
number is the generated @pipeline_iid@.

== Jobs

@GET \/projects\/:id\/pipelines\/:pipeline_id\/jobs@ returns much more: a
job carries four objects that live elsewhere in the store and are lifted
out rather than kept —

* @user@ — the same shape as everywhere else, interned into __users__ and
  referenced by @user_row@.
* @pipeline@ — the basic pipeline object of the pipeline the job belongs
  to, i.e. the row already in __pipelines__; @pipeline_id@ points at it.
* @commit@ — shared by every job of a pipeline, lifted into __commits__.
* @runner@ — shared by many jobs across many pipelines, lifted into
  __runners__. Absent on jobs that never ran (skipped, canceled early).

What remains (@runner_manager@, @project@, @artifacts@, @tag_list@, …)
stays verbatim in @rest@.

The scalars a job is queried by — status, stage, the four timestamps and
the two durations — are real columns rather than generated ones, filled by
the writer from the same JSON. They are a few bytes per job, so the
duplication that ruled real columns out for note bodies does not bite
here.

Jobs are keyed by an autoincrement @job_row@ with the GitLab id only
UNIQUE: the docs do not say whether job ids are instance-wide or
per-project, so nothing else is built on top of them.

== Runners and commits

__runners__ interns by JSON shape exactly as __users__ does. A runner
object is mutable state — @online@, @status@, @job_execution_status@
change between fetches — so this keeps one row per observed state, each
job pointing at the state its fetch saw; group by the generated
@runner_id@ to see a runner across states. __commits__ keys on the GitLab
id instead, since a commit is immutable and its sha already is a globally
unique id. @author_name@ and @author_email@ are real columns on commits;
the object is otherwise verbatim in @json@.

== Job logs

We store one cleaned up log per job at most.

We cascade job deletions to their logs. Which is also why we UPSERT jobs. This
avoids triggering the delete from the delete-and-insert combination.

== Test summaries

Every pipeline might produce a test_report based on the JUnit report.
We keep them as-is, and delete them during database gc when we delete
a pipeline. We is: @json@ NULL. @pipeline_updated_at@ is the
pipeline's @updated_at@ the summary was asked for, the same kind of stamp
as a record's @discussion_updated_at@, so a finished pipeline is not asked
again until it changes.

== Owners

@kind@ and @iid@ say which record a pipeline was fetched for. A pipeline
listed project-wide (@--pipelines --since@) has none unless its ref is a
merge request's (@refs\/merge-requests\/N\/…@); it is filed as
@kind = 'pipeline'@ with @iid@ its own @pipeline_id@, which a rewrite never
puts over a known owner.
-}
module FetchGitLab.Store.Schema.Pipeline (
    pipelineSchemaStatements,
    jobLogAndExpiryStatements,
    testSummaryStatements,
    retentionInterval,
    expirySql,
    nowSql,
) where

import Data.Text (Text)

{- | The pipeline and job tables, in an order that can be executed as given
(referenced tables first). Schema patch 1 rather than part of
'FetchGitLab.Store.Schema.schemaStatements'; it runs after them, and jobs
reference the __users__ table created there.
-}
pipelineSchemaStatements :: [Text]
pipelineSchemaStatements =
    [ "CREATE TABLE IF NOT EXISTS pipelines (\
      \  pipeline_id INTEGER PRIMARY KEY,\
      \  kind        TEXT NOT NULL,\
      \  iid         INTEGER NOT NULL,\
      \  rest        TEXT NOT NULL,\
      \  pipeline_iid INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.iid')) VIRTUAL,\
      \  project_id   INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.project_id')) VIRTUAL,\
      \  status       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.status')) VIRTUAL,\
      \  source       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.source')) VIRTUAL,\
      \  ref          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.ref')) VIRTUAL,\
      \  sha          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.sha')) VIRTUAL,\
      \  name         TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.name')) VIRTUAL,\
      \  web_url      TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.web_url')) VIRTUAL,\
      \  created_at   TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.created_at')) VIRTUAL,\
      \  updated_at   TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.updated_at')) VIRTUAL)"
    , "CREATE INDEX IF NOT EXISTS pipelines_record ON pipelines (kind, iid)"
    , "CREATE INDEX IF NOT EXISTS pipelines_status ON pipelines (status)"
    , "CREATE TABLE IF NOT EXISTS runners (\
      \  row_id      INTEGER PRIMARY KEY,\
      \  json        TEXT NOT NULL UNIQUE,\
      \  runner_id   INTEGER GENERATED ALWAYS AS (json_extract(json, '$.id')) VIRTUAL,\
      \  description TEXT    GENERATED ALWAYS AS (json_extract(json, '$.description')) VIRTUAL)"
    , "CREATE INDEX IF NOT EXISTS runners_runner_id ON runners (runner_id)"
    , "CREATE TABLE IF NOT EXISTS commits (\
      \  commit_id    TEXT PRIMARY KEY,\
      \  author_name  TEXT,\
      \  author_email TEXT,\
      \  json         TEXT NOT NULL)"
    , "CREATE TABLE IF NOT EXISTS jobs (\
      \  job_row         INTEGER PRIMARY KEY AUTOINCREMENT,\
      \  id              INTEGER NOT NULL UNIQUE,\
      \  pipeline_id     INTEGER NOT NULL REFERENCES pipelines(pipeline_id),\
      \  user_row        INTEGER REFERENCES users(row_id),\
      \  runner_row      INTEGER REFERENCES runners(row_id),\
      \  commit_id       TEXT REFERENCES commits(commit_id),\
      \  status          TEXT NOT NULL,\
      \  stage           TEXT NOT NULL,\
      \  created_at      TEXT NOT NULL,\
      \  started_at      TEXT,\
      \  finished_at     TEXT,\
      \  erased_at       TEXT,\
      \  duration        REAL,\
      \  queued_duration REAL,\
      \  rest            TEXT NOT NULL,\
      \  name           TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.name')) VIRTUAL,\
      \  ref            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.ref')) VIRTUAL,\
      \  tag            INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.tag')) VIRTUAL,\
      \  allow_failure  INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.allow_failure')) VIRTUAL,\
      \  coverage       REAL    GENERATED ALWAYS AS (json_extract(rest, '$.coverage')) VIRTUAL,\
      \  failure_reason TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.failure_reason')) VIRTUAL,\
      \  archived       INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.archived')) VIRTUAL,\
      \  source         TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.source')) VIRTUAL,\
      \  web_url        TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.web_url')) VIRTUAL,\
      \  artifacts_expire_at TEXT GENERATED ALWAYS AS (json_extract(rest, '$.artifacts_expire_at')) VIRTUAL)"
    , "CREATE INDEX IF NOT EXISTS jobs_pipeline ON jobs (pipeline_id)"
    , "CREATE INDEX IF NOT EXISTS jobs_status ON jobs (status)"
    ]

{- | The job log table and the @expire_at@ column of all three CI tables,
schema patch 5. Neither is part of the base schema: the table references
__jobs__, and the column is added to tables patch 1 created.

Unguarded, and not repeatable: @ADD COLUMN@ cannot run twice. The column is
in neither the base schema nor 'pipelineSchemaStatements', so every store —
fresh or migrated — runs this exactly once, which is what patch 3 relies on
too.

The @UPDATE@s give the rows a store already holds a retention period from
the migration rather than none: @ADD COLUMN@ cannot be @NOT NULL@ without a
constant default, and @expirySql@ is not constant, so the column arrives
NULL on every existing row. NULL means "not expired" to the purge, so those
rows would otherwise be kept forever.

No @ANALYZE@ and no index on @expire_at@: the only index here is the one
@UNIQUE@ implies, every query of __job_logs__ is an equality on it, and the
purge scans three small tables once per run.
-}
jobLogAndExpiryStatements :: [Text]
jobLogAndExpiryStatements =
    [ -- expire_at comes before raw_log on purpose. A log is megabytes and spills
      -- into overflow pages, and SQLite reaches a column after it only by
      -- walking that chain; the purge reads expire_at of every row, so putting
      -- it first keeps the scan to the table's own pages.
      "CREATE TABLE IF NOT EXISTS job_logs (\
      \  log_id    INTEGER PRIMARY KEY,\
      \  job_id    INTEGER NOT NULL UNIQUE REFERENCES jobs(id) ON DELETE CASCADE,\
      \  expire_at TEXT NOT NULL,\
      \  raw_log   TEXT NOT NULL)"
    , "CREATE TRIGGER IF NOT EXISTS jobs_delete_log AFTER DELETE ON jobs \
      \ BEGIN DELETE FROM job_logs WHERE job_id = OLD.id; END"
    , "ALTER TABLE pipelines ADD COLUMN expire_at TEXT"
    , "ALTER TABLE jobs ADD COLUMN expire_at TEXT"
    , "UPDATE pipelines SET expire_at = " <> expirySql <> " WHERE expire_at IS NULL"
    , "UPDATE jobs SET expire_at = " <> expirySql <> " WHERE expire_at IS NULL"
    ]

{- | The __test_summaries__ table, schema patch 6: one test report summary per
pipeline, deleted with it by cascade and, for connections without
@PRAGMA foreign_keys@, by trigger — as 'jobLogAndExpiryStatements' does for
a job's log. No @expire_at@: a summary lives exactly as long as its
pipeline. The generated columns are the pipeline-wide totals; the per-job
suites are @view_test_suites@.
-}
testSummaryStatements :: [Text]
testSummaryStatements =
    [ "CREATE TABLE IF NOT EXISTS test_summaries (\
      \  pipeline_id INTEGER PRIMARY KEY REFERENCES pipelines(pipeline_id) ON DELETE CASCADE,\
      \  pipeline_updated_at TEXT,\
      \  json        TEXT,\
      \  total   INTEGER GENERATED ALWAYS AS (json_extract(json, '$.total.count')) VIRTUAL,\
      \  success INTEGER GENERATED ALWAYS AS (json_extract(json, '$.total.success')) VIRTUAL,\
      \  failed  INTEGER GENERATED ALWAYS AS (json_extract(json, '$.total.failed')) VIRTUAL,\
      \  skipped INTEGER GENERATED ALWAYS AS (json_extract(json, '$.total.skipped')) VIRTUAL,\
      \  error   INTEGER GENERATED ALWAYS AS (json_extract(json, '$.total.error')) VIRTUAL)"
    , "CREATE TRIGGER IF NOT EXISTS pipelines_delete_test_summary AFTER DELETE ON pipelines \
      \ BEGIN DELETE FROM test_summaries WHERE pipeline_id = OLD.pipeline_id; END"
    ]

-- | How long a pipeline, job or log is kept after being written.
retentionInterval :: Text
retentionInterval = "+1 month"

{- | The @expire_at@ every write of a pipeline, job or log stores: now plus
'retentionInterval'.
Done in SQL to ensure we alway compare time the same way.
-}
expirySql :: Text
expirySql = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '" <> retentionInterval <> "')"

{- | Now, in the same format as 'expirySql'. What an @expire_at@ is compared
against to decide that a row has expired.
-}
nowSql :: Text
nowSql = "strftime('%Y-%m-%dT%H:%M:%SZ', 'now')"
