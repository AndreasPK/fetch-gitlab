# Why did an MR's CI fail? — a job for a subagent

Diagnosing a CI failure means a fetch, a few queries and reading a log that
runs to megabytes. Do not do it in your own context: launch a subagent, hand
it the brief below, and keep only its summary.

Before launching, settle three things (defaults in brackets):

- the MR number;
- which failed job to read [the first whose name contains `release`, else
  the first failed job that was not allowed to fail];
- how much of the log to read [the last 200 lines].

This writes to the store (`--pipelines`, `--job-log`), which is the
exception to "open it read-only": both take the store lock and refuse to run
beside a full fetch. If that happens the subagent reports it and stops;
nobody retries in a loop.

## The brief

Fill in `<MR>`, and replace the defaults if the user asked for something
else. Pass the rest as written — the subagent has not read this skill.

Prefer a sonnet subagent for this task.

```
Find out why CI failed for GHC merge request !<MR> and summarise the failure.
Store: ~/.fetch-gitlab/gitlab.db (SQLite). Only fetch-gitlab writes to it;
you query it with `sqlite3 -readonly`. A job log is megabytes: never SELECT
raw_log without a filter, a substr(), or a pipe into tail/grep.

1. Fetch the MR's pipelines (a few requests, seconds):
     fetch-gitlab --pipelines <MR>
   If it says another fetch-gitlab is running, report that and stop.

2. Check the newest pipeline:
     sqlite3 -readonly -header ~/.fetch-gitlab/gitlab.db \
       "SELECT pipeline_id, status, jobs, failed, failed_allowed, unfinished, web_url
          FROM view_mr_ci_status WHERE iid = <MR>"
   No row: the MR has no pipelines; report and stop. failed = 0: nothing
   failed (yet, if unfinished > 0); report the status and stop.

3. List the failed jobs:
     sqlite3 -readonly -header ~/.fetch-gitlab/gitlab.db \
       "SELECT job_id, name, stage, failure_reason, secs, runner, has_log
          FROM view_jobs
         WHERE iid = <MR> AND latest AND status = 'failed' AND NOT allow_failure
         ORDER BY name LIKE '%release%' DESC, finished_at"
   Take the first row: a job with "release" in its name if there is one,
   otherwise the earliest failure. Keep the whole list for the report.

4. Fetch that job's log (one request, megabytes), unless has_log is 1:
     fetch-gitlab --job-log <job_id>

5. Dump the log to a scratch file once, then read the end of it:
     sqlite3 -readonly ~/.fetch-gitlab/gitlab.db \
       "SELECT raw_log FROM job_logs WHERE job_id = <job_id>" > <scratch>/job.log
     tail -n 100 <scratch>/job.log
   Colour codes are already gone, but every line starts with a 32-character
   timestamp and stream prefix (`2026-…Z 01O `): `cut -c33-` for reading,
   and no `^` anchors in patterns.
   If the tail does not show the failure, find it further up:
   - testsuite failure (`tests failed` near the end): the summary starts at
       grep -n 'Unexpected failures:\|Unexpected stat failures:' job.log
     and each failure's diff is above it at `=====> <test>`. Do not grep
     for "error" or "fail" here — test names and Core dumps are full of both.
   - anything else:
       grep -n -E -i 'error:|fatal|panic|No space left|Killed' job.log | tail -n 40
   then read around the hit with `sed -n '<from>,<to>p'`.

6. Report, in under 400 words:
   - pipeline id, status and URL; how many jobs failed, and their names;
   - the job you read (name, job_id, runner, failure_reason);
   - what failed: the failing command or tests and the decisive error
     lines, quoted verbatim with their log line numbers;
   - whether it looks caused by the MR or by infrastructure (runner died,
     network, timeout, out of disk), and how sure you are;
   - whether the other failed jobs plausibly share the cause (same stage and
     failure_reason) or need their own look. Do not fetch their logs unless
     asked.
```

## After it reports

- Relay the summary; the quoted lines are the evidence, keep them.
- A different job, more lines, or a second log: send the same subagent a
  follow-up rather than starting over — the pipelines are already fetched.
- A testsuite failure (`Unexpected failures:` near the end) names tests;
  `Pipelines.md` has the schema if you need to go further yourself.
