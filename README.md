Tool to fetch all issues/mrs from gitlab as json.

```
fetch-gitlab --token FILE [--url URL] [--project NAMESPACE/PROJECT]
             [--backend jsonl|sqlite] [--tickets FILE] [--mrs FILE] [--db FILE]
             [--since WHEN] [--notes | --no-notes] [-v|--verbose] [--log FILE]

fetch-gitlab --convert --from jsonl|sqlite --to jsonl|sqlite
             --input-path PATH --output-path PATH [-v|--verbose]

fetch-gitlab --clear-timestamp [--backend jsonl|sqlite] [--db FILE]
             [--tickets FILE] [--mrs FILE] [-v|--verbose]
```

Each line of the output is one record together with its discussion:

```json
{"ticket": {...}, "discussion": [...], "discussion_updated_at": "..."}
{"mr": {...}, "discussion": [...], "discussion_updated_at": "..."}
```

`--token` takes the *path* to a file holding the access token, so the token
never appears in the process list. Defaults: `--url https://gitlab.haskell.org`,
`--project ghc/ghc`, `--tickets ~/.fetch-gitlab/tickets.jsonl`,
`--mrs ~/.fetch-gitlab/mrs.jsonl`. Directories that do not exist are created.
A token file that is missing, unreadable or empty is reported and the run stops
before anything else happens:

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

## Incremental fetching

Fetching is incremental. For tickets and merge requests alike the tool

1. reads the existing JSON lines file, if there is one,
2. takes the newest `updated_at` in it and asks GitLab only for records
   modified after that point (everything, if there is no file yet),
3. merges what comes back into what it had, keyed by the project local `iid`,
4. writes the whole set back out.

Step 2 is what `--since` replaces. The timestamp handed to GitLab is one second before the newest one we have, so
a record modified in the same instant as our newest cannot slip through an
exclusive comparison. Re-fetching a record we already have just replaces it.

Files are written to `<file>.tmp` and renamed into place, so an interrupted run
cannot leave a truncated store behind. A file that fails to parse aborts the
run rather than being silently overwritten.

Requests are limited to 1.5 per second. The limit is enforced in the HTTP
manager, so pagination and retries inside `gitlab-haskell` are covered too.
Two per second was enough to draw gitlab.haskell.org's anti-bot check
repeatedly during a long run, so the default backs off below it.

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

A run reads a store, merges what it fetched into what it read, and writes the
whole thing back, so two runs sharing a file would each throw away the other's
work. Both stores are therefore locked for the length of a run, and a second
run against either of them is turned away immediately rather than made to wait:

```
$ fetch-gitlab --token gitlab-token
ATTENTION Another fetch-gitlab is already running against ~/.fetch-gitlab/tickets.jsonl: pid 867046, started 2026-08-16 07:46:45 UTC
ATTENTION Its lock is held on ~/.fetch-gitlab/tickets.jsonl.lock; use --tickets/--mrs to work on a separate store
```

The lock is held on a `<file>.lock` beside each store rather than on the store
itself, because a store is replaced by renaming a temporary file over it and a
lock on the old file would stop guarding anything at the first checkpoint. Each
run records its pid and start time in the lock file, which is where the message
above gets its details.

That lock file is left behind when the run ends and is not a stale lock: the
lock itself belongs to the running process and the operating system drops it
when that process exits, however it exits. A leftover file with a long dead pid
in it holds nothing, and the next run overwrites it.

## Discussions

Unless `--no-notes` is given, each run also fetches the notes on every ticket
and merge request that has none yet or whose record has changed since the notes
were last fetched. `discussion_updated_at` records which version of the record
the discussion belongs to, which is what makes that comparison possible.

This is the expensive part: GitLab has no bulk endpoint for notes, so it costs
one request per object. A cold run over `ghc/ghc` is roughly 43k requests, about
eight hours at 1.5 per second. Interrupting is safe — entries are visited newest
first and the file is rewritten every 20 objects, so the next run picks up where
the last left off. An object whose notes fail to fetch is logged and retried on
the next run rather than aborting.

A run says how much of that it managed to avoid:

```
INFO Fetched 6 tickets (5 new or changed, 1 already current), writing 26259 to ...
INFO Discussions for tickets: 26254 already current, requesting 5 (0 never fetched, 5 changed since)
INFO All 16539 merge requests discussions are up to date, requesting none
```

An object is only asked about again once its own `updated_at` moves past the
`discussion_updated_at` we stored with its notes, so a run costs requests in
proportion to what actually changed rather than to the size of the project. The
"already current" count on the record line is the one thing fetched for nothing
each time, and it is normally 1: `updated_after` is asked from a second before
our newest record, so whatever sits in that second comes back again.

## Disk space

Measured against `ghc/ghc` (26,259 issues and 16,539 merge requests, sampled at
random and sized in this tool's own encoding), a complete store is about

| | with discussions | `--no-notes` |
| --- | --- | --- |
| `tickets.jsonl` | ~360 MB | ~110 MB |
| `mrs.jsonl` | ~210 MB | ~37 MB |
| total | **~560 MB** | ~150 MB |

Call it half a gigabyte, and 400–700 MB if you want a margin: the mean is what
drives the total and the distribution has a long tail — the median object costs
about 9 KB while the largest run past 500 KB.

Notes are roughly three quarters of that, at about 12 per object and 850 bytes
each. Both files are rewritten in full at every checkpoint, and to a `.tmp`
beside them first, so the peak requirement is twice the size of the larger file
on top of the rest.

## Backends

`--backend` picks where a run keeps what it fetches. **The default is
`sqlite`**, a single database at `~/.fetch-gitlab/gitlab.db`. Both backends
hold the same thing: a store written by one and a store written by the other
read back equal, which the test suite checks.

```
fetch-gitlab --token gitlab-token                             # ~/.fetch-gitlab/gitlab.db
fetch-gitlab --token gitlab-token --db /srv/ghc.db
fetch-gitlab --token gitlab-token --backend jsonl             # the two .jsonl files
```

`jsonl` is the older format described above: two files, one JSON object per
line. `sqlite` differs in two ways that matter.

**It writes only what changed.** A JSON lines store has to be rewritten from
the top at every checkpoint. Measured, one checkpoint of 20 objects:

| store | jsonl | sqlite |
| --- | --- | --- |
| 2 MB | 21 ms | 33 ms |
| 8 MB | 69 ms | 58 ms |
| 35 MB | 407 ms | 61 ms |
| 88 MB | 749 ms | 71 ms |

JSON lines costs more the more you have; SQLite costs the same. A full
`ghc/ghc` tickets store is ~360 MB, where the JSON lines checkpoint is a couple
of seconds against a checkpoint every ten.

**It shares repeated objects.** Users are stored once and referred to. In a
5.6 MB store that is 6,749 references to 176 distinct user objects.

It is not, however, smaller: 5.69 MB against 5.60 MB for the same data. What
sharing saves, the tables and their indexes spend again. Pick the backend for
how it writes and what you can ask it, not to save space.

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

## Converting between backends

`--convert` copies a store from one backend to another and talks to no server,
so it needs no `--token`:

```
fetch-gitlab --convert --from jsonl --to sqlite \
             --input-path ~/.fetch-gitlab --output-path ~/.fetch-gitlab/gitlab.db
```

`--input-path` and `--output-path` take one path each: the database file for
`sqlite`, and for `jsonl` the *directory* holding `tickets.jsonl` and
`mrs.jsonl`. Both ends may name the same backend, which is how a store gets
copied or rebuilt.

Both stores are locked for the duration, since either may be one a run is
using. Converting into a store that already holds records stops rather than
merging into it or writing over it — convert into a new store and move it into
place.

A store is not changed by the trip: converting to `sqlite` and back gives the
JSON lines files back byte for byte.

Because the default backend changed, a run that finds JSON lines files where
its database should be stops and says so, rather than quietly refetching a
project that is already on disk:

```
$ fetch-gitlab --token gitlab-token
ATTENTION There is a JSON lines store at ~/.fetch-gitlab/tickets.jsonl, ~/.fetch-gitlab/mrs.jsonl but no database at ~/.fetch-gitlab/gitlab.db
ATTENTION The default store is now sqlite, so this run would fetch the project again from the beginning rather than carry on from what is already there.
ATTENTION To keep it:  fetch-gitlab --convert --from jsonl --to sqlite --input-path ~/.fetch-gitlab --output-path ~/.fetch-gitlab/gitlab.db
ATTENTION To carry on as before, pass --backend jsonl.
```

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

Requests are capped at 1.5 per second, so lines should arrive about that often.
Several seconds of silence means the run has stopped rather than that it is
working through something large, which is the question the file exists to
answer. It is appended to rather than truncated, and the access token is sent
as a header, so it never appears in the logged URLs.

The count is honest: one line per request that is actually made. Each of these
lines is a request GitLab served, so the file doubles as a record of how much
was asked of the server.

`-v` puts the same trace lines on the terminal instead.

The executable caps its heap at 1 GB. A run holds one project's records and the
discussion it is currently fetching, which is tens of megabytes, so anything
approaching the cap is a leak rather than a large project and a heap overflow
says so where it happens. Raise it with `fetch-gitlab ... +RTS -M4G -RTS` if a
project ever genuinely needs more.

## Forcing a refetch

A discussion is only fetched again once its record has moved, which is what
keeps a run proportional to what changed. It also means a discussion that was
stored wrong stays wrong: the store believes it is current, so nothing looks
again. `--clear-timestamp` drops that belief:

```
fetch-gitlab --clear-timestamp                        # the default store
fetch-gitlab --clear-timestamp --db /srv/ghc.db
fetch-gitlab --clear-timestamp --backend jsonl
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

## Importing without the tool

[tools/jsonl-to-sqlite.sh](tools/jsonl-to-sqlite.sh) does a similar conversion
with nothing but `sqlite3`. It predates `--convert` and writes a different,
fully normalised schema — useful for querying a store from a machine without
this tool, but `--convert` is what to use for a store this tool will fetch into
again:

```
tools/jsonl-to-sqlite.sh [--tickets FILE] [--mrs FILE] [--db FILE] [--force]
```

It needs nothing but `sqlite3` — SQLite parses the JSON itself, so there is no
second implementation of the schema to keep in step. Tables are `users`,
`labels`, `milestones`, `tickets`, `merge_requests`, `notes`, and junctions for
labels, assignees and reviewers. Nested objects that occur once per record
(`references`, `_links`, `time_stats`, `task_completion_status`) are flattened
into columns; the ones that repeat become tables.

The import is lossless bar one field: `commands_changes`, which is `{}` on
every note. `discussion_updated_at` is kept, so the database holds everything a
fetch would need.

Measured on a 5.6 MB store (144 tickets, 150 merge requests, 5231 notes):

| | jsonl | sqlite |
| --- | --- | --- |
| on disk | 5.60 MB | 3.70 MB (0.66×) |
| gzipped | 0.95 MB | 1.04 MB |
| top note authors | 29 ms | 0.8 ms |
| tickets carrying a label | 29 ms | 0.01 ms |

The saving is the repetition: 6,749 user objects appear in that store and only
114 of them are distinct, which is 28% of the bytes. Gzip finds the same
repetition, so compressed archives are a wash — the win is in querying without
decompressing, and in not rewriting the file.

That last point is the real cost of JSON lines here, and it is arithmetic
rather than a benchmark: the store is rewritten in full every 20 objects, so a
cold run over `ghc/ghc` writes about 320 GB to end up with 560 MB on disk. At
254 MB/s of encoding a full-size tickets file takes ~1.4 s to write, against a
checkpoint every 13 s at 1.5 requests per second.

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
write/read roundtrip through the JSON lines store; fixtures live in
[test/data/](test/data/).
