{-# LANGUAGE OverloadedStrings #-}

-- | The relational shape of a merge request's pipelines and their jobs.
--
-- == Pipelines
--
-- @GET \/projects\/:id\/merge_requests\/:iid\/pipelines@ returns the /basic/
-- pipeline object: @id@, @iid@, @project_id@, @status@, @source@, @ref@,
-- @sha@, @name@, @web_url@, @created_at@ and @updated_at@ — no user, no
-- durations, no nested objects. So unlike a record there is nothing worth
-- lifting out of one; the object is kept verbatim and the fields the docs
-- promise are generated columns over it, as in "FetchGitLab.Store.Schema".
--
-- A pipeline is keyed by its project-unique @id@. Which merge request it was
-- fetched for is not part of the object, so the store has to remember it:
-- @kind@ and @iid@ name the owning record, exactly as the discussion tables
-- do. @iid@ is the merge request's iid — the pipeline's own project-local
-- number is the generated @pipeline_iid@.
--
-- == Jobs
--
-- @GET \/projects\/:id\/pipelines\/:pipeline_id\/jobs@ returns much more: a
-- job carries four objects that live elsewhere in the store and are lifted
-- out rather than kept —
--
-- * @user@ — the same shape as everywhere else, interned into __users__ and
--   referenced by @user_row@.
-- * @pipeline@ — the basic pipeline object of the pipeline the job belongs
--   to, i.e. the row already in __pipelines__; @pipeline_id@ points at it.
-- * @commit@ — shared by every job of a pipeline, lifted into __commits__.
-- * @runner@ — shared by many jobs across many pipelines, lifted into
--   __runners__. Absent on jobs that never ran (skipped, canceled early).
--
-- What remains (@runner_manager@, @project@, @artifacts@, @tag_list@, …)
-- stays verbatim in @rest@.
--
-- The scalars a job is queried by — status, stage, the four timestamps and
-- the two durations — are real columns rather than generated ones, filled by
-- the writer from the same JSON. They are a few bytes per job, so the
-- duplication that ruled real columns out for note bodies does not bite
-- here.
--
-- Jobs are keyed by an autoincrement @job_row@ with the GitLab id only
-- UNIQUE: the docs do not say whether job ids are instance-wide or
-- per-project, so nothing else is built on top of them.
--
-- == Runners and commits
--
-- __runners__ interns by JSON shape exactly as __users__ does. A runner
-- object is mutable state — @online@, @status@, @job_execution_status@
-- change between fetches — so this keeps one row per observed state, each
-- job pointing at the state its fetch saw; group by the generated
-- @runner_id@ to see a runner across states. __commits__ keys on the GitLab
-- id instead, since a commit is immutable and its sha already is a globally
-- unique id. @author_name@ and @author_email@ are real columns on commits;
-- the object is otherwise verbatim in @json@.
module FetchGitLab.Store.Schema.Pipeline
  ( pipelineSchemaStatements
  ) where

import Data.Text (Text)

-- | The pipeline and job tables, in an order that can be executed as given
-- (referenced tables first). Part of
-- 'FetchGitLab.Store.Schema.schemaStatements', appended after the main
-- tables because jobs reference the __users__ table created there.
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
