# fetch-gitlab

Dumps a GitLab project's issues and merge requests, with their discussions, to
JSON lines files. Incremental: a second run fetches only what changed.

## Command line

```
fetch-gitlab --token FILE [--url URL] [--project NAMESPACE/PROJECT]
             [--tickets FILE] [--mrs FILE] [--since WHEN]
             [--notes | --no-notes] [-v|--verbose]
```

| Flag | Default | Meaning |
| --- | --- | --- |
| `--token` | required | Path to a file holding the access token, not the token itself |
| `--url` | `https://gitlab.haskell.org` | Base URL of the GitLab instance |
| `--project` | `ghc/ghc` | Project as `namespace/project` |
| `--tickets` | `~/.fetch-gitlab/tickets.jsonl` | Issue output file |
| `--mrs` | `~/.fetch-gitlab/mrs.jsonl` | Merge request output file |
| `--since` | — | Override the incremental timestamp |
| `--notes` / `--no-notes` | `--notes` | Whether to fetch discussions |
| `-v`, `--verbose` | off | Log at trace level |

`--since` accepts a date (`2026-08-01`), an ISO 8601 timestamp
(`2026-08-01T12:00:00Z`), or a relative time (`2 days`, `1 week`,
`6 months ago`, `3d`). Units run from seconds to years; months and years use
calendar arithmetic.

## File format

One JSON object per line. Issues and merge requests differ only in the name of
the record field, `ticket` versus `mr`:

```json
{"ticket": {...}, "discussion": [...], "discussion_updated_at": "2026-08-11T09:54:19.873Z"}
{"mr": {...}, "discussion": [...], "discussion_updated_at": "2026-08-11T09:54:19.873Z"}
```

- `ticket` / `mr` — the GitLab object as `gitlab-haskell` models it. Fields the
  library does not model are dropped.
- `discussion` — the notes on that object. Absent if never fetched.
- `discussion_updated_at` — the record's `updated_at` at the time the
  discussion was fetched. A run compares it against the record's current
  `updated_at` to decide whether the discussion is stale, which is what makes
  an interrupted notes run resumable.

Lines are ordered by `iid`, which is also the key: re-fetching a record
replaces the old copy and keeps whatever discussion it had.

There is no backwards compatibility with a bare-record format; every line must
be a wrapper object.

## How a run proceeds

1. Resolve the store paths, creating their directory if it does not exist, then
   take an exclusive lock on both stores. A store already locked by another run
   aborts this one before anything else happens, including reading the token.
   Then read both files; a file that fails to parse aborts the run rather than
   being overwritten.
2. Read the token. A missing, unreadable or empty file is logged and the run
   stops; `readToken` returns `Either Text Text` rather than throwing.
3. Work out a starting timestamp per file: `--since` if given, otherwise one
   second before the newest `updated_at` in the file (the second guards
   against an exclusive comparison), otherwise nothing, meaning fetch
   everything.
4. Look up the project through `runGitLabWithManager`, the one call that
   checks the token, so the thousands that follow need not each pay a
   `/version` request to re-establish it.
5. Fetch records a page at a time, oldest change first, writing each page
   before asking for the next. See "Fetching in batches" below.
6. Unless `--no-notes`, fetch discussions for every entry that has none or
   whose record changed. Entries are visited newest first, and the store is
   written every 20 entries.

Files are written to `<file>.tmp` and renamed into place. An object whose notes
cannot be fetched is logged and skipped rather than aborting the run; the next
run retries it.

## Fetching in batches

`fetchRecords` asks for one page, merges it, writes it, and only then asks for
the next. A page is `recordsPerPage` = 100, GitLab's maximum, and one request:
writing more often would report nothing sooner and cost more requests to fetch
the same collection. The alternative, one library call that pages internally,
meant minutes with nothing logged and nothing saved — indistinguishable from a
wedged run, and all of it lost if stopped.

Pages are anchored on `updated_at` rather than numbered: each request asks for
records updated at or after the newest one held, sorted ascending. That is what
makes stopping halfway safe, and it is not a free choice.

- Numbered pages in the default order return the newest records first, so a
  half-finished run leaves a watermark past everything it had not fetched, and
  no later run asks for those records again. That is the same permanent silent
  loss the vendored `gitlabHTTPMany` patch exists to prevent, arrived at from
  the other direction.
- Numbered pages sorted by `updated_at` ascending fix the watermark but not the
  paging: a record edited while we page moves to the end of the collection and
  shifts a neighbour out of the numbering, unseen.

Anchoring on the timestamp has neither problem, since a record can only move
forward past an anchor we have already passed, and costs the same number of
requests. `updated_after` is inclusive, so each page repeats the record it was
anchored on; the anchor is rewound a further millisecond in case a server reads
it as exclusive, and the repeats are deduplicated by `iid` against the set seen
this run. A full page all stamped with one instant would leave nothing later to
anchor on; that steps past and logs at attention, and the records it skips are
older than the store's watermark so the next run collects them.

## Anti-bot challenges

`waitOutChallenge` wraps both GitLab runners, so every request a run makes is
covered without the record loop or the discussion loop knowing what a challenge
is. It retries on `GitLabChallengeError` and nothing else, on the ladder in
`challengeWaits` — 30s, 60s, 2m, 5m, 10m, 10m, a little under half an hour
against a run that takes eight.

The constructor comes from the vendored library rather than a substring match
on the message, because a challenge is transient where every other `GitLabError`
is not.

Exhausting the ladder aborts the run instead of returning the error. Returning
it would leave the caller to skip and carry on, spending the whole ladder again
on the next record and the one after; aborting costs nothing, since progress is
already checkpointed. Everything else is returned on the first attempt, so a bad
token still fails immediately.

The case that forced this: a challenge on the startup token check killed a run
outright, having fetched nothing, because until then the only thing that could
fail there was a genuinely bad token. Testing found it by starting a run 20
seconds after a previous run's last refusal.

## Not asking twice

`entryDiscussionFor` is what keeps the expensive half of a run proportional to
what changed: an entry is only re-requested once the record's `updated_at`
moves past it, so a run over an unchanged project issues no note requests at
all. The counts are logged on both sides of that decision — entries already
current, never fetched, and stale — so a run that starts re-fetching everything
says so rather than merely taking six hours.

Records are a different matter. `fetchSince` asks from a second before our
newest, so the records in that second always come back; `alreadyCurrent` counts
them and the number is logged. It is normally 1 per store and costs no extra
request, since records arrive in pages rather than one at a time. A large count
means the timestamp was further back than it had to be.

Tests cover a full write, read and re-merge cycle rather than the in-memory
check alone, because the store on disk is what the next run sees and a
timestamp that failed to survive encoding would silently make every run
re-fetch everything.

## Backends

The default is `sqlite`. `--backend jsonl` gets the older format.

`StoreBackend` has two operations that matter: `storeLoad` reads everything of
one record kind, and `storeSave` takes the store plus the keys that changed
since it was loaded. One handle serves both tickets and merge requests; which
is meant is decided by the `Record` instance the method is used at, which is
why a SQLite store can be one file and a JSON lines store two.

The changed-key set is the whole point of the interface. JSON lines ignores it
and rewrites the file; SQLite upserts those rows and leaves the rest. Measured
on a checkpoint of 20 objects, JSON lines goes 21 → 749 ms as the store grows
from 2 to 88 MB while SQLite goes 33 → 71 ms.

### How a record is stored relationally without being dissected

`Issue` and `MergeRequest` have some hundred fields between them, nested
`Pipeline` and `Epic` included, and a field missed would be a field dropped
from a dump that exists to be faithful. So `Store.Schema` splits rather than
dissects:

- the objects that repeat — users, milestones, labels — are lifted into their
  own tables, keyed on their exact JSON so that two copies differing in any
  field stay two rows (a note's author carries fewer fields than a ticket's),
- what is left is stored verbatim as `rest`,
- the columns worth querying are `GENERATED ... VIRTUAL` over `rest`, so they
  cost no space, can be indexed, and cannot disagree with it.

`splitObject` and `spliceObject` are inverses, and the tests check that on
every fixture and on the real store: 294 records and 5231 notes come back
identical. `liftedKeys` records which keys were removed, which is what
distinguishes an absent field from an empty list — a distinction the staleness
check depends on.

Two things learned the hard way, both now pinned by tests:

- Notes are keyed by `(kind, iid, position)`, not by GitLab's note id. Keying
  on the id made a store where one note belongs to several records lose all but
  the last, and a discussion is in any case an ordered list belonging to one
  record.
- The queryable columns were ordinary columns first, which stored every note
  body twice and made the database half again the size of the JSON lines files.

## Converting

`--convert` is a load from one backend and a save into the other, and knows
nothing about either beyond `StoreBackend` — which is the return on having the
class. `--input-path`/`--output-path` take one path each, so `pathSpec` reads a
JSON lines store as the directory holding `tickets.jsonl` and `mrs.jsonl`.

It has its own parser rather than being a mode of the fetching one, since it
talks to no server and requiring `--token` for it would be asking for something
that will not be used. Both stores are locked, and a target that already holds
records stops the conversion rather than being merged into or written over.

Because the default backend changed, `checkForOldStore` stops a run that finds
JSON lines files where its database should be and points at `--convert`. It
only fires when nothing was said about where to keep things, since anyone
naming a store has said what they meant. Without it, upgrading and running
yesterday's command would spend six hours arriving back where it started.

## The vendored gitlab-haskell

`cabal.project` builds `gitlab-haskell` from `vendor/gitlab-haskell`, a patched
1.4.0.0. Three upstream bugs, all detailed in `vendor/gitlab-haskell/PATCHES.md`
and reproduced standalone in `repro/`:

- `gitlabHTTPMany` decoded a page as a whole and, when that failed, returned
  the pages so far as a **success** and stopped paging. Two mistyped records in
  `ghc/ghc` cost 1853 of 2353 merge requests, 79%, with no way for the caller
  to tell. It now decodes element by element, skips the record it cannot read,
  and pages to the end.
- `merge_request_source_project_id` was `Int`; GitLab returns null when the
  source project has been deleted. Now `Maybe Int`. GraphQL confirms
  `targetProjectId` is non-null, so that one is left alone.
- `parseOne` discarded the decode error entirely, making "cannot parse"
  indistinguishable from "does not exist". It now says so on stderr.

The first of those is the one that mattered: because a run's next
`updated_after` comes from the newest record it holds, and a truncation keeps
precisely the newest records, everything dropped fell permanently out of reach
of later runs. Silent, deterministic data loss. After the patch the same query
returns all 2353.

Two further changes are additions rather than fixes, giving control the library
does not otherwise offer without changing what the existing functions do:

- `gitlabGetPage`, with `projectIssuesPage` and `mergeRequestsWithPage`, returns
  a single page instead of paging to the end. This is what "Fetching in batches"
  above is built on.
- `runGitLabWithManagerUnchecked` is `runGitLabWithManager` without the
  `/version` token check it runs before **every** action. One action per record
  is exactly how discussions are fetched, so that check was doubling the whole
  discussion phase: around 28,000 extra requests on `ghc/ghc`, four hours at two
  a second. The checked version is still called once at the start, so a bad
  token is still reported immediately.

## Watching a run

`--log FILE` writes at trace level while the terminal keeps info. The two
sinks are separate `Logger`s combined with `<>`; `runLogT` is given `LogTrace`
whenever a file is in use, since a message filtered out there would never reach
the file, and the terminal logger filters for itself on `lmLevel`.

What makes the file useful is that the rate limited manager announces every
request at trace level, which also makes it a record of what was asked of the
server. At 1.5 requests a second, several seconds of silence means stopped
rather than busy.

The hook is `managerWrapException`, which is not what its name suggests it is
for. The obvious one, `managerModifyRequest`, runs **twice** per request:
`responseOpen` applies it to the request it is given and again inside the
redirect loop before each attempt. That charged two turns of the rate limiter
per request, so a limit of two a second delivered one, and the log claimed twice
the traffic actually made. `managerWrapException` wraps the whole of
`responseOpen` and so runs exactly once per request, retries included; the
default wrapper is still called, so exceptions are translated as before. The
test asserts one announcement per request against a refused connection, which
exercises the hook without needing a server.

## Forcing a refetch

`--clear-timestamp` sets `entryDiscussionFor` to `Nothing` across a store, so
every discussion is stale and the next run fetches it. The notes are kept —
only the claim that they are current is dropped — so the store stays usable
until each is replaced, and repeating the command does nothing the second time.

It cannot move where records are fetched from: that comes from `latestUpdate`,
a property of the records themselves rather than any stored timestamp. The
command prints the current starting point and points at `--since`.

## Size

For `ghc/ghc`, 26,259 issues and 16,539 merge requests, so about 43k note
requests and six hours for a cold run. Sized from a random sample: a complete
store is roughly 360 MB of tickets and 210 MB of merge requests, ~560 MB in
all, or ~150 MB with `--no-notes`. Notes are about three quarters of the bytes.
The distribution is heavily tailed — median object ~9 KB, largest past 500 KB —
so the mean is what to extrapolate from.

## Locking

Each store is guarded by a `<file>.lock` beside it, held for the whole run.
The lock cannot go on the store itself: the store is replaced by a rename at
every checkpoint, which would leave the lock holding the replaced file while a
second run locked the new one. The lock file is only ever created, locked and
rewritten in place.

On taking the lock a run writes `{"pid": ..., "started_at": ...}` into the file,
which is what lets a run that is turned away name what is in its way. The file
is not deleted on release and its contents are not what grants the lock, so a
leftover file from a finished run is not a stale lock — the operating system
releases the real lock when the holding process dies, and the next run
overwrites the record. Locking never waits; a run that cannot have both stores
logs and exits 1.

Two subtleties, both of which the tests pin down:

- GHC refuses to open a file twice for writing within one process, so
  `withStoreLocks` treats an `openFile` "resource busy" as a held lock rather
  than letting the exception escape. This is why the holder is read back
  through the handle already open rather than by opening the lock file again.
- A same process nested lock is caught by that GHC check rather than by the
  operating system, so the test suite also re-runs its own executable as a
  child (`--hold-lock`) to exercise the real cross process lock.

Requests are capped at 1.5 per second, enforced in the HTTP manager so
`gitlab-haskell`'s internal pagination and retries are covered too. Discussions
cost one request per object, so a cold run over a large project takes hours —
roughly six for `ghc/ghc`. Interrupting it is safe.

## Modules

| Module | Role |
| --- | --- |
| `FetchGitLab.Options` | optparse-applicative parser, `Command`, `Options`, `Backend` |
| `FetchGitLab.Convert` | `--convert`, copying a store between backends |
| `FetchGitLab.ClearTimestamp` | `--clear-timestamp`, forcing discussions to be refetched |
| `FetchGitLab.Since` | `--since` parsing and resolution against now |
| `FetchGitLab.Store` | `Record` class, `Entry`, merge, staleness, JSON lines files |
| `FetchGitLab.Store.Class` | `StoreBackend`, the interface a backend implements |
| `FetchGitLab.Store.Schema` | Entities, relations, lift/splice, the SQL tables |
| `FetchGitLab.Store.JsonLines` | The JSON lines backend |
| `FetchGitLab.Store.Sqlite` | The SQLite backend, via sqlite-simple |
| `FetchGitLab.Store.Backend` | `--backend` to an open store, and the paths to lock |
| `FetchGitLab.Lock` | Exclusive store locks, `LockInfo` holder record |
| `FetchGitLab.JsonLines` | JSON lines encoding |
| `FetchGitLab.Logging` | Terminal and `--log` file loggers at different levels |
| `FetchGitLab.RateLimit` | Rate limiter and the manager that obeys it |
| `FetchGitLab.Fetch` | `run`, orchestration, paged record fetch, discussion loop |

`Record` is the class tying a type to the store: `recordKey` (the `iid`),
`recordUpdatedAt`, and `recordField` (the JSON field name). Instances exist for
`Issue` and `MergeRequest`.

## Building

```
cabal build
cabal test
```

Tests use real GitLab responses in `test/data/` as fixtures and hit no network.
