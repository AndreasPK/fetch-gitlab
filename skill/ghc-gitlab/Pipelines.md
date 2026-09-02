# Pipelines and jobs in a fetch-gitlab store

Pipelines are only ever fetched on request — a project the size of GHC runs
one per push, so nothing fetches them unasked. **An MR with no rows in
`pipelines` is an MR nobody fetched pipelines for, not an MR without CI.**

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
Verbatim JSON in `rest` with the useful fields generated from it:
`pipeline_iid`, `status`, `source`, `ref`, `sha`, `web_url`, `created_at`,
`updated_at`.

`jobs` is keyed by an autoincrement `job_row` with the GitLab job id in
`id` (UNIQUE). Real columns: `pipeline_id`, `status`, `stage`,
`created_at`/`started_at`/`finished_at`/`erased_at`, `duration` and
`queued_duration` (REAL, seconds). Generated from `rest`: `name`, `ref`,
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

The failed jobs of an MR's newest pipeline, with who ran them:

```sql
SELECT j.name, j.stage, round(j.duration) AS secs, j.web_url,
       json_extract(r.json, '$.description') AS runner
  FROM jobs j
  JOIN pipelines p ON p.pipeline_id = j.pipeline_id
  LEFT JOIN runners r ON r.row_id = j.runner_row
 WHERE p.kind = 'mr' AND p.iid = 16366
   AND p.pipeline_id = (SELECT max(pipeline_id) FROM pipelines
                         WHERE kind = 'mr' AND iid = 16366)
   AND j.status = 'failed'
 ORDER BY j.finished_at;
```

Gotchas:

- `runner_row IS NULL` means the job never ran (skipped, canceled while
  queued) — a real value on every job that executed.
- `duration` is NULL until a job finishes; `queued_duration` can dwarf it
  when runners are busy.
- A job's `id` (in the `id` column) is what the API and the
  `/-/jobs/<id>` URL want; `job_row` is only the store's key.

## Fetching a job's log

The log ("trace") is not stored — fetch it from the API when needed, using
the job's `id`:

```
curl -s -H "PRIVATE-TOKEN: $(cat ~/.fetch-gitlab/gitlab-token)" \
  "https://gitlab.haskell.org/api/v4/projects/1/jobs/<job_id>/trace" -o job.log
```

`1` is `ghc/ghc`'s project id (`ghc%2Fghc` URL-encoded also works). The token
is required — gitlab.haskell.org answers 401 without it, even for public
jobs. Logs run to megabytes and carry ANSI colour plus CR-overwritten
progress lines — clean before grepping:

```
sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/.*\r//' job.log | grep -n -i error | tail
```

The failing part is almost always at the end; GitLab truncates very long
logs from the top, so the end is also all you may get.
