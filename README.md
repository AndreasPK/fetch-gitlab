# Gitlab MR/Issue cache builder

This tool/repo has two purposes:

* It provides a haskell program to create and update a snapshot of ghc-gitlab
  tickets and MRs.
* It provides a skill file that AI tools can use to query that data
  reasonably efficiently.

TLDR:
* Install via `cabal install`, ideally also install the `sqlite3` binary
* Create a read-only api_read token under `~/.fetch-gitlab/gitlab-token`
* Run `fetch-gitlab` to fetch MRs/Tickets
* cp `skills/fetch-gitlab/ ~/.claude/skills/` or similar to install the skill file.

Ideally you aquire a snapshot of `gitlab.db` to avoid a very long initial sync.

This creates a sqlite.db file under `~/.fetch-gitlab/gitlab.db` that will contain all
MRs/Tickets and their discussions.

You can query this database manually, or via the fetch-gitlab tool itself. But it's
mostly meant to be consumed with scripts/agents, primarily via a set of hand curated
views.

## Other things of note for fellow humans:

The tool uses a restrictive rate limit. As a result starting a sync from scratch
*will* take hours. But starting from a recent snapshot should take at most a few
minutes.

Fetching is incremental, and uses transactions. So not much is lost when killing
a fetch command while it runs.

When ghc gitlab is under load it throws Anubis challenges even to API users. In
these cases we do exponential backoff.

Pipeline/job data is purged after some (calendar) time on startup. Tickets/MRs
are cached forever.

Once synced the db is 500MB-1GB in size.

## Agent info

Anything below this point is honestly not that interesting unless you are an
Agent so you can stop reading here.

## Full options

```bash
# Caching MRs/Tickets
fetch-gitlab [--token FILE] [--url URL] [--project NAMESPACE/PROJECT]
             [--db FILE]
             [--since WHEN] [--notes | --no-notes]
             [-v|--verbose] [--log FILE]

# Fetching pipelines and jobs
fetch-gitlab
      --pipelines [MR | --since WHEN] [--with-summary]
      [--token FILE] [--url URL] [--project NAMESPACE/PROJECT]
      [--db FILE] [-v|--verbose] [--log FILE]

# Fetch a jobs log:
fetch-gitlab --job-log JOB_ID
             [--token FILE] [--url URL] [--project NAMESPACE/PROJECT]
             [--db FILE] [-v|--verbose] [--log FILE]

fetch-gitlab --clear-timestamp [--db FILE] [-v|--verbose]
```

A store holds one entry per record: the ticket or merge request, its
discussion, and the record version that discussion was fetched for. See "The
store" below for the tables and how to query them.

| Flag | Default | Meaning |
| --- | --- | --- |
| `--token FILE` | `~/.fetch-gitlab/gitlab-token` | Path to a file holding the access token, not the token itself |
| `--url URL` | `https://gitlab.haskell.org` | Base URL of the GitLab instance |
| `--project NS/PROJECT` | `ghc/ghc` | Project as `namespace/project` |
| `--backend sqlite` | `sqlite` | Store format; `sqlite` is the only one |
| `--db FILE` | `~/.fetch-gitlab/gitlab.db` | Database to fetch into |
| `--since WHEN` | — | Override the incremental timestamp; with `--pipelines` and no MR, fetch the pipelines created after it |
| `--notes` / `--no-notes` | `--notes` | Whether to fetch discussions |
| `--pipelines MR` | — | Fetch one merge request's pipelines and jobs instead of records |
| `--pipelines --since WHEN` | — | Fetch every pipeline of the project created after WHEN, and its jobs |
| `--with-summary` | off | With `--pipelines`: also each pipeline's test report summary |
| `--job-log JOB_ID` | — | Fetch one job's log instead of records; the job must already be in the store |
| `--log FILE` | — | Append a trace level log, one line per request, to FILE |
| `--clear-timestamp` | — | Mark every stored discussion stale so the next run refetches it |
| `-v`, `--verbose` | off | Log at trace level on the terminal |

`--pipelines` needs exactly one of `MR` and `--since`. `--clear-timestamp`
accepts the fetch-only flags and ignores them.

`--token` takes the *path* to a file holding the access token, so the token
never appears in the process list. Directories that do not exist are created.
A token file that is missing, unreadable or empty is reported and the run
stops before it talks to the server:

```
$ fetch-gitlab --token gitlab-tokne
ATTENTION Cannot read the access token: no such file: "gitlab-tokne"
```

`--since` overrides the incremental timestamp described below and fetches
everything modified after the given point. It takes a date (`2026-08-01`), an
ISO 8601 timestamp (`2026-08-01T12:00:00Z`), or a git style relative time:

```
fetch-gitlab --token gitlab-token --since "2 weeks"
fetch-gitlab --token gitlab-token --since "6 months ago"
fetch-gitlab --token gitlab-token --since 3d
```

Units are seconds, minutes, hours, days, weeks, months and years, in long,
plural or abbreviated form. Months and years are counted on the calendar, so
one month before the 31st clips to the end of the previous month rather than
overshooting.

## What a run does

1. Takes an exclusive lock on the store, creating its directory if needed. A
   store locked by another run aborts this one before anything else happens,
   including reading the token.
2. Removes the pipelines, jobs and logs whose month is up (see "Pipelines and
   job logs"). This is the only thing that deletes from a store.
3. Reads the token.
4. Works out a starting timestamp per record kind: `--since` if given,
   otherwise one second before the newest `updated_at` stored, otherwise
   nothing, meaning fetch everything.
5. Checks the token against the server once.
6. Fetches records a page of 100 at a time, oldest change first, writing each
   page before asking for the next.
7. Unless `--no-notes`, fetches the discussion of every record that has none
   or whose record changed, newest first.

## Incremental fetching

Fetching is incremental. For tickets and merge requests alike the tool asks
the store for its newest `updated_at`, asks GitLab only for records modified
after that point (everything, if there is no store yet), and writes each page
as it arrives, keyed by the project local `iid`. `--since` replaces the
timestamp. It is handed to GitLab one second early, so a record modified in
the same instant as our newest cannot slip through an exclusive comparison;
re-fetching a record we already have just replaces it.

A store that cannot be read aborts the run rather than being silently written
over.

Requests are limited to 1.5 per second. The limit is enforced in the HTTP
manager, so pagination and retries inside `gitlab-haskell` are covered too.
Two per second was enough to draw gitlab.haskell.org's anti-bot check
repeatedly during a long run, so the default backs off below it.

## Memory

A run never holds the store: only the page of records it is writing and, for
the notes phase, the list of records still owed a discussion — an id and a
timestamp each. Its memory tracks a page and what changed, not the project's
history. The 1 GB heap cap is far more than that needs; overflowing it is a
leak worth reporting, not a large project.

## Anti-bot challenges

`gitlab.haskell.org` answers sustained traffic with an Anubis interstitial: an
HTML page served with **HTTP 200**, so nothing short of parsing the body tells
it apart from the data that was asked for. It clears on its own once traffic
drops — observed at around ten minutes — and it is tied to the source address
rather than to the process, so starting a fresh run does not reset it.

A run waits one out rather than failing on it, backing off 30s, 60s, 2m, 5m,
10m, 10m before giving up and stopping:

```
ATTENTION The server answered with an anti-bot challenge rather than data.
          Waiting 30s before asking again (5 further attempts before giving up)
```

Every other error still fails on the first try, so a bad token is reported
immediately rather than after half an hour of waiting. Giving up stops the run
rather than skipping the record and carrying on, since a run that carried on
would spend the whole ladder again on the next record and the one after that.
Stopping costs nothing: what has been fetched is already written, and the next
run resumes from it.

## One run at a time

In principle we could allow concurrent writes but it would just cause us to run
into rate limits faster. So we currently use a lock file to prevent concurrent
fetches that would just duplicate work.

The lock is a `<db file>.lock` beside the store, held for the whole run and
by `--clear-timestamp`. It records the holder's pid and start time, which is
what a run that is turned away reports. The file is left behind on exit and is
not a stale lock: the operating system releases the real lock when the process
dies, and the next run overwrites the record. Locking never waits; a run that
cannot have the lock exits 1.

## Discussions

Unless `--no-notes` is given, each run fetches not just the MR/Issue but also
it's full discussion (notes in gitlab lingo). But we avoid refetching already
known objects by using time/last_updated based filters on the queries.

This is the expensive part: GitLab has no bulk endpoint for notes, so it costs
one request per object. A cold run over `ghc/ghc` is roughly 43k requests, about
eight hours at 1.5 per second. Interrupting is safe — objects are visited newest
first and each discussion is written as it arrives, so the next run picks up
where the last left off. An object whose notes fail to fetch is logged and retried on
the next run rather than aborting.

A run says how much of that it managed to avoid:

```
INFO Fetched 6 tickets (5 new or changed, 1 already current), store now holds 26259
INFO Discussions for tickets: 26254 already current, requesting 5
INFO All 16539 merge requests discussions are up to date, requesting none
```

The "already current" count on the `Fetched` line is normally 1: records are
always asked for from one second before the store's newest. A large count
means the timestamp was further back than it had to be.

## Pipelines and job logs

Neither is fetched unless asked for; GHC runs a pipeline per push.

```
fetch-gitlab --pipelines 16366     # the MR's pipelines and their jobs
fetch-gitlab --pipelines --since 1w --with-summary
                                   # every pipeline created in the last week,
                                   # with its test counts per job
fetch-gitlab --job-log 2589581     # one job's log, into the job_logs table
sqlite3 ~/.fetch-gitlab/gitlab.db \
  "SELECT raw_log FROM job_logs WHERE job_id = 2589581" | grep -n -i error | tail
```

`--job-log` takes the job's GitLab id (`jobs.id`, the number in its URL), and
the job must already be in the store, so run `--pipelines` for its merge
request first. Running either again replaces what was stored; refreshing
pipelines keeps the logs and test summaries, deleting a job deletes its log.

`--pipelines --since` skips the finished pipelines the store already holds,
so running it again over an overlapping window is cheap. `--with-summary`
adds the JUnit test report summary of each pipeline that has one; read it
through `view_test_suites`, or raw from `test_summaries` (one row per pipeline,
GitLab's JSON verbatim). It costs one request more per pipeline. A pipeline
without JUnit reports gets a row with `json` NULL, so it is not asked again.

A `--pipelines --since` run (GHC: about 25 pipelines a day) files a pipeline
whose ref is `refs/merge-requests/N/…` under merge request N. Any other —
master, schedules, branches — is stored as `kind = 'pipeline'` with `iid` its
own pipeline id. Such a run gives a merge request only the pipelines in the
window, so `view_mr_ci_status.pipelines` counts those, not all of them; use
`--pipelines MR` for the complete set.

Any failure aborts a pipeline run rather than skipping; what it wrote before
stays.

Colour codes, section markers and carriage-return progress rewrites are
stripped before the log is stored, so `grep` and `LIKE` work on it; line
numbers still match GitLab's. The log as sent is not kept: it is at
`/api/v4/projects/:id/jobs/:job_id/trace`.

Pipelines, jobs and logs are kept for a month from when they were last
fetched, and a run removes what has run out before it fetches anything — CI
data is bulky and the store is there for the records. Fetching a log keeps its
merge request's pipelines and jobs for as long, since a log goes when its job
does. Fetching again is all it takes to get something back.

What follows from that:

- A merge request with no pipelines, or a job with no log, may be one whose
  month ran out rather than one nobody ever fetched. The two look the same;
  fetching again answers either and renews the month.
- The expiry is the `expire_at` column of `pipelines`, `jobs` and `job_logs`,
  a UTC timestamp (`2026-10-18T08:50:20Z`) that sorts as text.
- `users` is never purged, since records and notes share it. `commits` and
  `runners` lose only the rows no job refers to any more.
- The file does not shrink; freed pages are reused. There is no `VACUUM`.

## Disk space

For `ghc/ghc` — 26,259 issues and 16,539 merge requests at the time of
measuring — a complete store is roughly 360 MB of tickets and 210 MB of merge
requests, about 560 MB in all, or about 150 MB with `--no-notes`. Notes are
about three quarters of the bytes. The median object is about 9 KB and the
largest is past 500 KB. Fetched CI data comes on top of that.

## The store

A run keeps what it fetches in a single SQLite database, at
`~/.fetch-gitlab/gitlab.db` unless `--db` says otherwise:

```
fetch-gitlab --token gitlab-token                             # ~/.fetch-gitlab/gitlab.db
fetch-gitlab --token gitlab-token --db /srv/ghc.db
```

`--backend` exists for the day there is a second place to put a store; `sqlite`
is the only value it takes today. Two things about the one there is are worth
knowing.

**It writes only what the run just learned.** A write says one thing — this
page of records, or this record's notes — and touches nothing else, so it
costs the same on a full store as on an empty one, and a second run against
the same store could only duplicate work, never undo it. The lock (see "One
run at a time") is about the wasted hours, not about safety.

**It shares repeated objects.** like users and milestones and more. These
are interned by their exact JSON and referred to.
In a 5.6 MB store that is 6,749 references to 176
distinct user objects. It does not make the store smaller — what sharing saves,
the tables and their indexes spend again — but it is what makes asking about a
person cheap.

The database is meant to be queried directly:

```sql
SELECT u.username, count(*) FROM note_users nu
  JOIN users u ON u.row_id = nu.user_row GROUP BY 1 ORDER BY 2 DESC;
SELECT iid, title FROM records WHERE kind = 'ticket' AND state = 'opened';
```

`title` and `state` are `GENERATED ... VIRTUAL` columns over the JSON each row
already holds, so they cost nothing to store, can be indexed, and cannot drift
from the record they describe. See
[Store/Schema.hs](src/FetchGitLab/Store/Schema.hs) for the tables and
[Store/Class.hs](src/FetchGitLab/Store/Class.hs) for what a backend has to do.

Issues and merge requests share the `records` table and are told apart by
`kind`, `ticket` versus `mr`. Fields `gitlab-haskell` does not model are
dropped from a record. `records` and `notes` also carry an indexed `ref`, the
GitLab notation for the record (`#123` for a ticket, `!123` for a merge
request), so `WHERE ref = '#123'` is the cheap way to name one.
`discussion_updated_at` is the record's `updated_at` at the time its
discussion was fetched, NULL if it never was; a discussion is stale when the
record has moved past it.

### Views

Eleven views spare you the joins;
[Store/Schema/Views.hs](src/FetchGitLab/Store/Schema/Views.hs) defines them.

| View | One row per | Notable columns |
| --- | --- | --- |
| `view_tickets`, `view_mrs` | record | author, assignees, labels, milestone, `notes_stale` |
| `view_ticket`, `view_mr` | header, then each note oldest first | `seq`, `text` rendered as Markdown |
| `view_notes` | note | author, `system`, `is_import` (Trac migration), `len` |
| `view_links` | cross-reference GitLab recorded as a system note | `rel`, `target_kind`, `target_ref` |
| `view_people` | user | |
| `view_mr_ci_status` | merge request with fetched pipelines | newest pipeline's status, `jobs`, `failed`, `failed_allowed`, `unfinished` |
| `view_mr_jobs` | job of an MR's pipeline | `latest` (newest pipeline), `job_id` (what `--job-log` takes), `has_log` |
| `view_jobs` | job, MR or not | `kind`, `source`, `git_ref` |
| `view_test_suites` | test job of a pipeline with a stored summary | `name`, `job_id`, `total`, `success`, `failed`, `skipped`, `error` |

```sql
-- a ticket as a transcript
SELECT text FROM view_ticket WHERE ref = '#123' ORDER BY seq;
-- the failed jobs of an MR's newest pipeline
SELECT job_id, name FROM view_mr_jobs WHERE iid = 16366 AND latest AND status = 'failed';
```

In `view_jobs`, filter on `kind = 'mr' AND iid = N`; `iid` alone scans.

## Watching a run

Records are fetched a page at a time and each page is written before the next
is asked for, so the terminal reports progress as often as there is progress to
report:

```
INFO Fetching tickets: 100 so far, written up to 2026-07-29 10:40:32.908 UTC
INFO Fetching tickets: 199 so far, written up to 2026-08-11 14:31:09.262 UTC
INFO Fetched 304 tickets (304 new or changed, 0 already current), store now holds 304
```

A page is one request and GitLab caps it at a hundred records, so a smaller
batch would not report anything sooner — it would only take more requests to
fetch the same collection.

Stopping a run halfway is safe. Pages are asked for oldest change first, so a
store holding half a collection asks for exactly the other half next time
rather than starting again or, worse, carrying on past what it missed.

For the detail underneath that, `--log FILE`:

```
fetch-gitlab --token gitlab-token --log /tmp/fetch.log
tail -f /tmp/fetch.log
```

The terminal keeps the level it had, normally info. The file gets everything
down to trace, which is a line per HTTP request:

```
2026-08-16 10:12:41 INFO  fetch-gitlab: Fetching tickets updated after 2026-08-13 10:12:41 UTC
2026-08-16 10:12:41 TRACE fetch-gitlab: GET https://gitlab.haskell.org/api/v4/version
2026-08-16 10:12:44 TRACE fetch-gitlab: GET https://gitlab.haskell.org/api/v4/projects/ghc%2Fghc?statistics=true
```

Requests are capped at 1.5 per second, so lines should arrive about that
often; several seconds of silence means the run has stopped, not that it is
working through something large. The file is appended to, one line per
request actually made, and the token is sent as a header so it never appears
in the logged URLs. `-v` puts the same trace lines on the terminal instead.

## Forcing a refetch

A discussion is only fetched again once its record has moved, which is what
keeps a run proportional to what changed. It also means a discussion that was
stored wrong stays wrong: the store believes it is current, so nothing looks
again. `--clear-timestamp` drops that belief:

```
fetch-gitlab --clear-timestamp                        # the default store
fetch-gitlab --clear-timestamp --db /srv/ghc.db
```

```
INFO Cleared the discussion timestamp of 294 of 294 tickets; the next run will fetch 294 discussions
INFO The tickets themselves are still fetched from 2026-08-16 08:43:52 UTC onwards; to go back further use --since, for example --since "1 year"
```

The notes themselves are kept, so the store stays usable until each is
replaced; only the claim that they are up to date is dropped. Running it twice
does nothing the second time, so it is safe to repeat after an interrupted run.
It takes the same lock a fetching run does.

It does not move where *records* are fetched from. That is worked out from the
newest `updated_at` in the store — a property of the records themselves, not a
timestamp anything could clear — so `--since` is the way to reach further back,
and the command prints the current starting point and says so.

## Building

```
cabal build
cabal test
```

`cabal.project` builds `gitlab-haskell` from [vendor/gitlab-haskell/](vendor/gitlab-haskell/)
rather than from Hackage. That is a patched 1.4.0.0 working around three
upstream bugs, the worst of which silently discarded 79% of a collection and
reported success; [vendor/gitlab-haskell/PATCHES.md](vendor/gitlab-haskell/PATCHES.md)
says what was changed and why, and [repro/](repro/) is a standalone reproducer
for filing them. Delete the directory and the `cabal.project` entry once a
release carries the fixes.

The test suite checks that real GitLab issues and merge requests survive a
write/read roundtrip through the store; fixtures live in
[test/data/](test/data/).
