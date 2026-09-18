# Pipelines and jobs in a fetch-gitlab store

Pipelines are only ever fetched on request — a project the size of GHC runs
one per push, so nothing fetches them unasked. **An MR with no rows in
`pipelines` is an MR nobody fetched pipelines for (or fetched them over a
month ago — see "Expiry"), not an MR without CI.**

## Workflow: what failed in an MR's CI

(To have the whole of this done and summarised by a subagent, use
`CiFailure.md` instead.)

1. Fetch (refetch if the pipeline may still be running — the store only
   knows what the last fetch saw):

   ```
   fetch-gitlab --pipelines 16366
   ```

2. One row for the MR's newest pipeline:

   ```sql
   SELECT pipeline_id, status, jobs, failed, failed_allowed, unfinished
     FROM view_mr_ci_status WHERE iid = 16366;
   ```

   No row: nothing was fetched. `unfinished > 0`: still running, `failed`
   can grow. `failed_allowed` jobs failed without failing the pipeline.

3. Its failed jobs:

   ```sql
   SELECT job_id, name, stage, allow_failure, failure_reason, secs, runner, has_log
     FROM view_jobs
    WHERE iid = 16366 AND latest AND status = 'failed'
    ORDER BY finished_at;
   ```

4. For a job worth reading, `fetch-gitlab --job-log <job_id>`, then grep the
   log (see "Fetching a job's log").

`view_mr_ci_status`: one row per MR with pipelines in the store — `ref, iid,
pipeline_id, status, sha, created_at, updated_at, pipelines, jobs, failed,
failed_allowed, unfinished, web_url, expire_at`.

`view_jobs`: one row per job of any pipeline — `ref, iid, pipeline_id,
latest, pipeline_status, job_id, name, stage, status, allow_failure,
failure_reason, started_at, finished_at, secs, runner, has_log, web_url`.
`latest` = belongs to the MR's newest pipeline; drop it to see a job's
history across pushes (`WHERE iid = … AND name = …`). Filter both views on
`iid`, not `ref`: only `iid` is indexed.

## Fetching an MR's pipelines

```
fetch-gitlab --pipelines <mr>
```

(The token is read from `~/.fetch-gitlab/gitlab-token` by default;
`--token FILE` for another.)

One request for the pipeline list, one per pipeline for its jobs, written to
the default store (`--db FILE` for another). It fetches nothing else — no
records, no notes. Refetching the same MR replaces what is there, so it is
also how to refresh a running pipeline's status. It writes, so it takes the
store lock: it will refuse to run beside a full fetch.

## Schema

`pipelines` is keyed by the project-unique `pipeline_id`; `kind`/`iid` name
the MR it was fetched for (`kind` = `'mr'`, `iid` = the `!16366` number).
Real columns: `expire_at` (see "Expiry"). Verbatim JSON in `rest` with the
useful fields generated from it: `pipeline_iid`, `project_id`, `status`,
`source`, `ref`, `sha`, `name`, `web_url`, `created_at`, `updated_at`.

`jobs` is keyed by an autoincrement `job_row` with the GitLab job id in
`id` (UNIQUE). Real columns: `pipeline_id`, `status`, `stage`,
`created_at`/`started_at`/`finished_at`/`erased_at`, `duration` and
`queued_duration` (REAL, seconds), `expire_at`. Generated from `rest`: `name`, `ref`,
`tag`, `allow_failure`, `coverage`, `failure_reason`, `archived`, `source`,
`web_url`, `artifacts_expire_at`. Still inside `rest` as JSON:
`runner_manager`, `artifacts`, `tag_list`, `project`.

Four objects are lifted out of a job's `rest`, so `json_extract(rest,
'$.user')` is always NULL, like a record's author:

- `user_row` → `users(row_id)` — same interned users table as everywhere.
- `runner_row` → `runners(row_id)` — interned **per observed state**
  (`online`/`status` change between fetches); one physical runner is one
  `runner_id` across several rows, so group by the generated `runner_id`,
  and read `description` for the machine's name.
- `commit_id` → `commits(commit_id)` — keyed by the sha (TEXT, not a
  number); `author_name`/`author_email` are real columns, the rest is in
  `json`. Commits have no back-pointer; find a commit's jobs by searching
  `jobs`.
- the nested `pipeline` object is dropped outright — every field of it is in
  the `pipelines` row.

Gotchas:

- `runner_row IS NULL` means the job never ran (skipped, canceled while
  queued) — a real value on every job that executed.
- `duration` is NULL until a job finishes; `queued_duration` can dwarf it
  when runners are busy.
- A job's `id` (in the `id` column) is what the API and the
  `/-/jobs/<id>` URL want; `job_row` is only the store's key.

## Fetching a job's log

Logs are only fetched on request, one job at a time, by the job's `id`:

```
fetch-gitlab --job-log <job_id>
```

The job must already be in `jobs` (run `--pipelines <mr>` first); otherwise
the run says so and downloads nothing. One request, typically megabytes. It
writes, so it takes the store lock like `--pipelines`.

`job_logs`: `log_id`, `job_id` (= `jobs.id`, UNIQUE), `expire_at`, `raw_log`
(TEXT). One row per job; fetching again replaces it, which is how to update
the log of a job that was still running. Refetching pipelines keeps logs;
deleting a job deletes its log.

The stored log is already clean — no ANSI colour, no `section_start` markers,
no CR-overwritten progress lines — and its line numbers match GitLab's, so
grep it directly:

```
sqlite3 ~/.fetch-gitlab/gitlab.db \
  "SELECT raw_log FROM job_logs WHERE job_id = <job_id>" | grep -n -i error | tail
```

Which failed jobs still need their log fetched: `has_log` in `view_jobs`.

Gotchas:

- The failing part is almost always at the end; GitLab truncates very long
  logs from the top, so the end is also all you may get.
- A log is megabytes: never `SELECT raw_log` into your context unfiltered.
  Pipe it through `grep`/`tail`, or cut in SQL with `substr(raw_log, -4000)`.
- The log as sent (colour codes and all) is not stored. It is almost never
  what you want; if it is:
  `curl -s -H "PRIVATE-TOKEN: $(cat ~/.fetch-gitlab/gitlab-token)"
  "https://gitlab.haskell.org/api/v4/projects/1/jobs/<job_id>/trace"`
  (`1` is `ghc/ghc`).

## Expiry

CI data is the one thing a store forgets. `pipelines`, `jobs` and `job_logs`
all carry `expire_at`, a fixed-width UTC string (`2026-10-18T08:50:20Z`) that
compares and sorts as text. Every write sets it a month ahead; the start of
the next `fetch-gitlab` run deletes what has passed, with a line saying what
went. Records and notes never expire.

```sql
-- what is left of an MR's CI, and for how long
SELECT p.pipeline_id, p.expire_at, count(j.id) AS jobs,
       sum(l.job_id IS NOT NULL) AS logs
  FROM pipelines p
  LEFT JOIN jobs j ON j.pipeline_id = p.pipeline_id
  LEFT JOIN job_logs l ON l.job_id = j.id
 WHERE p.kind = 'mr' AND p.iid = 16366
 GROUP BY p.pipeline_id;
```

Gotchas:

- **Missing is ambiguous**: never fetched and expired look identical. Either
  way, refetch — `--pipelines <mr>` renews the whole MR, `--job-log <id>`
  renews the log *and* every pipeline and job of its MR (a log dies with its
  job, so it drags the unit along), never shortening a date already further
  off.
- A pipeline row survives while any job of it is unexpired, so you never see
  a job without its pipeline — the other way round happens.
- `commits` and `runners` lose the rows no job refers to any more; `users`
  never expires.
- The file does not shrink when rows go: the pages are reused, there is no
  `VACUUM`.
