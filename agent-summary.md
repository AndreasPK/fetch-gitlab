# fetch-gitlab

Dumps a GitLab project's issues and merge requests, with their discussions,
into a SQLite database. Incremental: a second run fetches only what changed.
This file is for agents *using* the binary; how it is built is under
`.ai/` (start at `.ai/AGENTS.md`).

## Command line

```
fetch-gitlab [--token FILE] [--url URL] [--project NAMESPACE/PROJECT]
             [--backend sqlite] [--db FILE] [--since WHEN]
             [--notes | --no-notes | --pipelines MR | --job-log JOB_ID]
             [-v|--verbose] [--log FILE]

fetch-gitlab --clear-timestamp [--backend sqlite] [--db FILE] [-v|--verbose]
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `--token` | `~/.fetch-gitlab/gitlab-token` | Path to a file holding the access token, not the token itself |
| `--url` | `https://gitlab.haskell.org` | Base URL of the GitLab instance |
| `--project` | `ghc/ghc` | Project as `namespace/project` |
| `--backend` | `sqlite` | Which store format; `sqlite` is the only one |
| `--db` | `~/.fetch-gitlab/gitlab.db` | Database to fetch into |
| `--since` | — | Override the incremental timestamp |
| `--notes` / `--no-notes` | `--notes` | Whether to fetch discussions |
| `--pipelines MR` | — | Fetch one merge request's pipelines and jobs instead of records |
| `--job-log JOB_ID` | — | Fetch one job's log instead of records; the job must already be in the store |
| `--log FILE` | — | Append a trace level log, one line per request, to FILE |
| `--clear-timestamp` | — | Mark every stored discussion stale so the next run refetches it |
| `-v`, `--verbose` | off | Log at trace level on the terminal |

`--since` accepts a date (`2026-08-01`), an ISO 8601 timestamp
(`2026-08-01T12:00:00Z`), or a relative time (`2 days`, `1 week`,
`6 months ago`, `3d`). Units run from seconds to years; months and years use
calendar arithmetic.

`--clear-timestamp` accepts the fetch-only flags and ignores them.

## What a store holds

One row per record in `records`. Issues and merge requests share the tables
and are told apart by `kind`, `ticket` versus `mr`:

- the record — the GitLab object as `gitlab-haskell` models it. Fields the
  library does not model are dropped.
- its discussion — the notes on that object. Absent if never fetched.
- `discussion_updated_at` — the record's `updated_at` at the time the
  discussion was fetched, and NULL if it never was. A run compares it against
  the record's current `updated_at` to decide whether the discussion is
  stale, which is what makes an interrupted notes run resumable.

The key is the `iid`: re-fetching a record replaces the old copy and keeps
whatever discussion it had. Repeated objects — users, milestones, labels —
are interned in their own tables and referenced; the rest of each object is
kept verbatim, with the queryable columns (`title`, `state`, ...) generated
from it, so nothing in the database can disagree with the JSON it holds.
`records` and `notes` also carry `ref`, the row's name in GitLab notation
(`#123` for a ticket, `!123` for a merge request; on a note, the record it
belongs to), indexed, so `WHERE ref = '#123'` is the cheap way to name one.
Pipelines, jobs and job logs, when fetched, land in tables of their own, and
are the one thing a store forgets again: they carry an `expire_at` a month
out (see "CI data expires").

Nine views spare a reader the joins: `view_tickets` and `view_mrs` (one row
per record with author, assignees, labels, milestone and `notes_stale`),
`view_ticket` and `view_mr` (one record as a thread, a header row then its
notes oldest first, each row's `text` rendered as Markdown, so
`SELECT text FROM view_ticket WHERE ref = '#123' ORDER BY seq` prints a
transcript), `view_notes` (every note with its author, `system`, `is_import`
for the Trac migration's, and `len`), `view_links` (the cross-references
GitLab records as system notes, split into `rel`, `target_kind` and a
joinable `target_ref`) and `view_people`. Two more cover CI:
`view_mr_ci_status` (one row per merge request with fetched pipelines: its
newest pipeline's status and `jobs`/`failed`/`failed_allowed`/`unfinished`
counts) and `view_jobs` (one row per job, `latest` marking the newest
pipeline's, `job_id` being what `--job-log` takes, `has_log`); the failed jobs
of an MR are `SELECT job_id, name FROM view_jobs WHERE iid = N AND latest AND
status = 'failed'`. `Store.Schema.Views` defines them;
the `ghc-gitlab` skill is written around them.

## How a run proceeds

1. Take an exclusive lock on the store, creating its directory if it does
   not exist. A store already locked by another run aborts this one before
   anything else happens, including reading the token. A store that fails to
   open aborts the run rather than being overwritten.
2. Remove the pipelines, jobs and logs whose month is up, and the commit and
   runner rows only they referred to. Logged when it removed something. This
   is the only thing that deletes from a store; `--clear-timestamp` does not.
3. Read the token. A missing, unreadable or empty file is reported and the run
   stops.
4. Work out a starting timestamp per record kind: `--since` if given,
   otherwise one second before the newest `updated_at` stored for it,
   otherwise nothing, meaning fetch everything.
5. Check the token against the server once.
6. Fetch records a page of 100 at a time, oldest change first, writing each
   page before asking for the next. Stopping halfway is safe: the next run
   asks for exactly what is missing.
7. Unless `--no-notes`, fetch discussions for every record that has none or
   whose record changed. Records are visited newest first, and each
   discussion is written as it arrives.

Every write is a transaction stating one thing the run just learned — a page
of records, or one record's notes — so an interrupted run leaves everything
it had fetched, and a write never undoes another one. An object whose notes
cannot be fetched is logged and skipped rather than aborting the run; the
next run retries it.

## Not asking twice

A discussion is only re-requested once the record's `updated_at` moves past
the stored `discussion_updated_at`, so a run over an unchanged project issues
no note requests at all. The counts are logged on both sides of that decision
— records already current, and records to request — so a run that starts
re-fetching everything says so rather than merely taking six hours.

Records always come back for the second before the store's newest one; the
"already current" count on the record line is that, and it is normally 1. A
large count means the timestamp was further back than it had to be.

## Anti-bot challenges

`gitlab.haskell.org` answers sustained traffic with an interstitial page
served as HTTP 200. A run recognises it and waits it out on a ladder of 30s,
60s, 2m, 5m, 10m, 10m before giving up. Giving up aborts the run rather than
skipping the object, since everything fetched is already written and carrying on
would spend the whole ladder again on the next one. Every other error fails
on the first attempt, so a bad token is reported immediately. The challenge is
tied to the source address, not the process, so restarting straight away does
not help.

## Locking

Each store is guarded by a `<file>.lock` beside it, held for the whole run
and by `--clear-timestamp`. The file records the holder's pid and start time,
which is what a run that is turned away reports. The file is left behind on
exit and is not a stale lock: the operating system releases the real lock
when the process dies, and the next run overwrites the record. Locking never
waits; a run that cannot have the lock exits 1. Two runs could not corrupt
a store — every write states one thing the run just fetched — but they would
spend the same hours twice against one token.

## Pipelines on request

`--pipelines <mr>` fetches the pipelines of one merge request and the jobs of
each, instead of fetching records at all. Pipelines are never fetched unasked:
a project the size of GHC runs a pipeline per push, so following them for
every merge request would dwarf the records themselves. A run is one request
for the pipeline list plus one per pipeline for its jobs; the objects are
stored complete, not through the library's typed models.

Any failure aborts the run rather than skipping: re-running costs a handful
of requests. Refetching a merge request's pipelines replaces what was there.
A store from before the pipeline tables existed gains them at the next open.

## Job logs on request

`--job-log <job_id>` fetches the log of one job into `job_logs (log_id,
job_id, raw_log)`, one row per job, replaced when fetched again. `job_id` is
the job's GitLab id — `jobs.id`, not `jobs.job_row`. The job must already be
in the store: run `--pipelines <mr>` first, or the run stops before
downloading anything and says so. One request, a few megabytes.

`raw_log` is TEXT and always cleaned: no ANSI escape sequences, no section
markers, no control characters but newline and tab, and of a line rewritten
with carriage returns only the last version. `grep`, `LIKE`, `instr` and
`substr` all work on it. Newlines are untouched, so a line number in
`raw_log` is the line number in GitLab's view. The log as the server sent it
is not stored; in the rare case it matters, ask the API:
`GET /api/v4/projects/:id/jobs/:job_id/trace`.

Refetching a merge request's pipelines keeps the logs of its jobs. Deleting
a row of `jobs` deletes its log, in any connection, `PRAGMA foreign_keys` on
or off. A store from before `job_logs` existed gains it at the next open.

## CI data expires

`pipelines`, `jobs` and `job_logs` each carry `expire_at`, a fixed-width UTC
text (`2026-10-18T08:50:20Z`, so it compares and sorts as text). Every write
of a row sets it to a month ahead, and the start of the next fetching run
removes whatever has passed — nothing else deletes from a store, and
`--clear-timestamp` does not.

What follows for a reader:

- **An MR with no rows in `pipelines`, or a job with no row in `job_logs`,
  may be one whose month ran out** rather than one nobody ever fetched. Both
  cases look the same; refetching with `--pipelines`/`--job-log` is the
  answer to either, and renews the month.
- Fetching a job's log also extends every pipeline of that merge request and
  every job of those pipelines to at least the log's date, never shortening
  one. A log goes when its job does, and half a merge request's pipelines
  would read as a merge request that ran one pipeline.
- A pipeline is only removed once no job of it is left, so a purge never
  leaves a job without its pipeline row.
- `users` is never purged: it is shared with the records and the notes.
  `commits` and `runners` rows lose only what no job refers to any more.
- The file does not shrink. The pages are reused by what the store grows into
  next; there is no `VACUUM`.

## Forcing a refetch

`--clear-timestamp` marks every discussion in a store stale, so the next run
fetches all of them. The notes are kept — only the claim that they are current
is dropped — so the store stays usable until each is replaced, and repeating
the command does nothing the second time.

It cannot move where records are fetched from: that comes from the newest
`updated_at` among the records themselves. The command prints the current
starting point and points at `--since`.

## Size

For `ghc/ghc`, 26,259 issues and 16,539 merge requests, so about 43k note
requests for a cold run: six to eight hours at the 1.5 requests a second the
tool allows itself, pagination and retries included. Interrupting is safe.
Sized from a random sample, a complete store is roughly 360 MB of tickets and
210 MB of merge requests, ~560 MB in all, or ~150 MB with `--no-notes`. Notes
are about three quarters of the bytes; the median object is ~9 KB and the
largest past 500 KB, so extrapolate from the mean.

A run holds a page of records and the list of discussions still to fetch,
never the store. The 1 GB heap cap is a leak detector, not a limit a project
can reach.

## Watching a run

`--log FILE` appends at trace level while the terminal keeps info; `-v` puts
the trace lines on the terminal instead. Trace is one line per HTTP request,
so at 1.5 requests a second several seconds of silence means stopped rather
than busy. The token is sent as a header and never appears in the logged
URLs.

## Building

```
cabal build
cabal test
```

Tests hit no network. `gitlab-haskell` is built from a patched copy under
`vendor/`, not from Hackage.
