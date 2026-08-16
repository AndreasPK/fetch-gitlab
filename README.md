Tool to fetch all issues/mrs from gitlab as json.

```
fetch-gitlab --token FILE [--url URL] [--project NAMESPACE/PROJECT]
             [--tickets FILE] [--mrs FILE] [--since WHEN]
             [--notes | --no-notes] [-v|--verbose]
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

Requests are limited to two per second. The limit is enforced in the HTTP
manager, so pagination and retries inside `gitlab-haskell` are covered too.

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
six hours at two per second. Interrupting is safe — entries are visited newest
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

## SQLite

The stores have a schema hiding in them, and [tools/jsonl-to-sqlite.sh](tools/jsonl-to-sqlite.sh)
makes it explicit:

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
checkpoint every 10 s at two requests per second.

## Building

```
cabal build
cabal test
```

The test suite checks that real GitLab issues and merge requests survive a
write/read roundtrip through the JSON lines store; fixtures live in
[test/data/](test/data/).
