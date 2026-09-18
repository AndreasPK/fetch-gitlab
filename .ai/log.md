# Log

Design decisions, major changes and outcomes of experiments, ISO-timestamped,
newest last, never rewritten. Decision entries are headed
`— decision: <question>`; `grep -n '^## .* — decision:' log.md` lists them.

## 2026-09-03T09:30+00:00 — decision: how does a store record additive schema changes?

**Decision.** A second `meta` key, `schema_patch_version`, counts the entries
of `schemaPatches` applied to the store. `migrate` (Store.Sqlite) runs at
open: a store whose count is current costs one read; otherwise the base
statements and the unapplied patches run in one transaction and the count is
written last. A store counted higher than the binary knows is left alone.

**Reason.** `schema_version` encodes compatibility only and is not bumped for
additive changes, so it cannot say which additions a store has. Re-running
every `IF NOT EXISTS` statement at open costs ~2 ms, but `ALTER TABLE ... ADD
COLUMN` (needed for the planned `ref` generated columns) is not idempotent
and must run exactly once. Not lowering a higher count matters because
patches are additive — an older binary reads such a store fine — and
lowering it would make the newer binary repeat a non-repeatable patch.

Files: `src/FetchGitLab/Store/Schema.hs`, `src/FetchGitLab/Store/Sqlite.hs`.
Verified on copies: v1 store gains the count and is a no-op on the second
open; a store marked 99 keeps 99; a fresh store gets the current values.

## 2026-09-03T09:45+00:00 — decision: what does schema_version mean now that additions are patches?

**Decision.** `schema_version` is bumped only for a change an older binary
would misread; a store recording any other version is refused, and migrating
it is a job for something outside the binary. `compatibleVersions` is
retired: every compatible change is an entry of `schemaPatches`.
`schemaVersion` goes back to 1 and the pipeline tables, formerly "version 2",
are patch 1.

**Reason.** With a patch count in the store, a list of readable older
versions duplicates it — every compatible version is by definition a patch.
Version 2 only added tables, so it is what the mechanism is for. The one
cost: a store created fresh by the version-2 binary recorded
`schema_version = 2` and is now refused until that row is set to 1 (Andi's
stores record 1). `pipelineSchemaStatements` are `IF NOT EXISTS`, so a store
that already has the tables runs patch 1 as a no-op and just gains the count.

Files: `src/FetchGitLab/Store/Schema.hs`, `src/FetchGitLab/Store/Sqlite.hs`,
`.ai/summary/Schema.md`. 53/53 tests pass; a store recording version 2 is
refused with "store was written by schema version 2, this is version 1".

## 2026-09-03T10:10+00:00 — .ai layout settled

`.ai/` is committed except `scratch/` and `tmp/` (both in `.gitignore`).
Topic files live under `summary/`; `Schema.md` moved there with `git mv`.
Decisions are recorded in this file rather than in an external store.

## 2026-09-03T11:00+00:00 — implementation detail moved out of agent-summary.md

`agent-summary.md` had grown into the implementation summary: function
names, the `Kept` discussion case, the `managerWrapException` hook, the
lock's GHC subtleties, the vendored patches. That text now lives in topic
files under `summary/` — `fetch.md`, `network.md`, `store.md`, `lock.md`,
`vendored-gitlab-haskell.md`, `modules.md` — and `agent-summary.md` keeps
only what an agent running or querying the binary needs. The empty
`summary/implementation.md` placeholder is gone.

One stale claim was corrected in the move: "files are written to
`<file>.tmp` and renamed into place" described the JSON lines backend. The
SQLite backend writes in place inside a transaction; the lock still sits
beside the store so a renaming backend would be safe, and the lock test
simulates one.

## 2026-09-03T11:30+00:00 — decision: changed-key checkpoints (recorded retrospectively)

**Decision.** `storeSave` takes the set of changed keys and a backend
writes only those. Made when SQLite replaced the JSON lines backend.

**Reason.** A checkpoint of 20 objects costs 33 → 71 ms as a store grows
from 2 to 88 MB with upserts; rewriting the store went 21 → 749 ms over the
same range, which at a checkpoint every ten seconds would not scale to
`ghc/ghc`.

Files: `src/FetchGitLab/Store/Class.hs`, `src/FetchGitLab/Store/Sqlite.hs`.

## 2026-09-03T11:30+00:00 — notes out of memory (recorded retrospectively)

Loading a 17,052 record store with 229k notes for a fetch: 301 MB live and
813 MiB peak heap holding the notes, 155 MB and 340 MiB without
(`storeLoadWithoutNotes` plus `forgetWritten` after each checkpoint).
Projected to `ghc/ghc`'s ~42.8k records: ~2 GB against ~850 MiB, the
difference between overflowing the 1 GB cap and fitting under it.

## 2026-09-03T11:30+00:00 — topic files cut to maps

The six topic files written this morning were the moved prose of
`agent-summary.md` and repeated the haddocks. `AGENTS.md` now defines a
topic file as a map — locations, cross-module invariants, traps, live
constraints — with three tests per sentence and a one screen target; the
files were cut to that. Rationale stays in the code comments where it was
found to already live, or in this log.

## 2026-09-03T11:02+00:00 — timestamps round the same way on every path

Found while working out whether the discussion staleness check can move
into SQL. `updated_at` in the store is not GitLab's text: `rest` is `toJSON`
of the parsed record, so the column has been through aeson, which trims
trailing zeros from the fraction (`.550Z` → `.55Z`, `.000Z` → `Z`; aeson
2.2.2.0, checked directly). `discussion_updated_at` is `encodeTime`, also
aeson. On the real store 4,298 of 42,929 records carry a trimmed fraction
and 0 disagree with their stamp — the comparison is exact only because both
sides use one encoder.

Two consequences. A SQL-side check `discussion_updated_at IS NOT updated_at`
is sound today and stays sound only while every writer of either column
matches `encodeTime`; a record written from raw JSON, or a stamp copied from
GitLab's text, would break it silently. And the trimmed text does not sort
chronologically (`Z` collates after `.` and digits), so `MAX(updated_at)` and
`ORDER BY updated_at` are off by under a second; `fetchSince` already rewinds
a full second, so nothing is wrong today, but exact ordering has to parse.

Decision: document the invariant rather than change the encoding now. The
alternatives considered — a fixed-width newtype on every timestamp field in
the vendored types, or storing GitLab's raw JSON so `rest` and the stamp are
verbatim (`.SSSZ`, fixed width, sorts correctly, and no fields dropped) —
belong with the write-through store refactor discussed the same day, not
before it.

Pinned by "both timestamp columns are written by one encoder", which checks
the trimmed forms aeson produces and that the two columns agree for whole
seconds, trailing zeros and sub-millisecond precision.

Files: `src/FetchGitLab/Store/Sqlite.hs` (`encodeTime`,
`sqliteTimestampTexts`), `src/FetchGitLab/Store/Schema.hs`, `test/Main.hs`,
`.ai/summary/store.md`.

## 2026-09-03T11:54+00:00 — decision: write-through store: a write states what the run learned

**Decision.** A run no longer holds the store. `storeLoad`/`storeSave` of a
whole `Map` are gone; a backend now offers two writes — `storeWriteRecords`
("these records are as GitLab has them") and `storeWriteDiscussion` ("these
are record *n*'s notes, as of the version I planned against") — and four
questions: `storeDiscussionPlan`, `storeRecordCount`, `storeLatestUpdate`,
`storeRecordVersions`. `storeLoad`/`storeLookup` survive as the reader's
view. Each write is one `BEGIN IMMEDIATE` transaction.

**Reason.** The snapshot design allowed a lost update, not just a wasteful
one. `writeEntry` wrote the discussion columns and note rows from the
in-memory entry, so a checkpoint could undo a write another writer made in
between: two runs both see record 5 as `NeverFetched`; A fetches its
discussion and writes the notes; B's next record checkpoint writes entry 5
still holding `NeverFetched`, which is not the `Kept` branch, so it deletes
A's notes. The file lock was the only thing standing between that and a
silently truncated store — and the lock's own header still argued from
whole-file clobbering that the SQLite backend had already made impossible.
With writes that restate nothing, concurrent writers can only duplicate
work. Run memory becomes O(page) + O(plan) rather than O(store), which
retires the `Kept`/`NeverFetched` distinction, `storeLoadWithoutNotes`,
`forgetWritten` and `checkpointEvery` with it.

**The lock stays**, with a different job: two runs against one project would
spend the same eight hours twice and double the request rate against the one
token that may make the requests, at a server that answers sustained traffic
with an anti-bot challenge. It is refused rather than queued, and names the
holder. No `locking_mode = EXCLUSIVE`: readers must be able to query during
a fetch.

**`BEGIN IMMEDIATE`, not `withTransaction`.** sqlite-simple's
`withTransaction` issues a deferred `BEGIN`, which takes a read snapshot and
asks for the write lock at the first write; if another connection wrote in
between, that fails with `SQLITE_BUSY_SNAPSHOT`, which `busy_timeout` does
not wait on — waiting cannot help a stale snapshot. An immediate `BEGIN`
contends up front, where the timeout does apply.

**The stamp is passed in, not read from the row.** `storeWriteDiscussion`
takes the `updated_at` the plan was made from; there is no
`SET discussion_updated_at = updated_at` anywhere. If the record moved
between planning and writing, stamping the notes with the *new* version
would claim they cover an edit they were fetched before, and nothing would
ever look again. Stamping the planned version leaves the record stale, so
the race costs one refetch next run — the cheap direction to be wrong in.
Pinned by "a discussion stamp is the one the plan gave, not the row's".

**`has_discussion` is gone** (schema patch 2, guarded by a
`pragma_table_info` query so a store created since never runs it). "Fetched"
is `discussion_updated_at IS NOT NULL`, and the plan is one query:
`discussion_updated_at IS NULL OR discussion_updated_at IS NOT updated_at`.
The extra disjunct is for a record GitLab sent no `updated_at` for at all —
both columns NULL would compare equal and its discussion would never be
fetched. After `--clear-timestamp` a fetched-but-empty discussion is
indistinguishable from one never fetched; both are refetched, which costs
one request to learn. Dropping a column is the first patch an older binary
could not read a store back with, which the rule says should be a
`schema_version` bump; it is not, because bumping refuses every store that
exists instead of migrating it, and the only readers are this binary and SQL
that a patched store answers as well as it did before.

**`ORDER BY updated_at DESC` and `MAX(updated_at)`** inherit the sub-second
imprecision of the previous entry; the plan's order only decides what an
interrupted run reached first, and `fetchSince` rewinds a whole second.

**Deferred, and worth doing later.** A fixed-width timestamp newtype on the
vendored types, or — better — storing GitLab's raw JSON as `rest` so `rest`
and the stamp are verbatim `.SSSZ`: fixed width, sorts correctly, and no
fields dropped by the typed models. Both are changes to what is stored
rather than to how it is written, so neither belonged in this refactor.

Files: `src/FetchGitLab/Store.hs`, `Store/Class.hs`, `Store/Sqlite.hs`,
`Store/Schema.hs`, `Fetch.hs`, `ClearTimestamp.hs`, `Lock.hs`,
`test/Main.hs`, `fetch-gitlab.cabal`, the topic files and `README.md`.
56/56 tests pass.

## 2026-09-03T12:20+00:00 — `ref` columns (patch 3, point 1 of the views plan)

`records` and `notes` gain `ref TEXT GENERATED ALWAYS AS (CASE kind WHEN
'ticket' THEN '#' ELSE '!' END || iid) VIRTUAL` with indexes `records_ref`
and `notes_ref (ref, position)`, as schema patch 3 (`refStatements`,
Schema.hs). Point 1 of the views plan the record-table session wrote
(`tmp/views.md`, git-ignored): a ref computed inside a view is not indexable
(one thread by ref 0.33 s), the column with its index is (8 ms). The views
themselves are that session's patch, appended after this one.

Unguarded on purpose: `ADD COLUMN` is not repeatable, but the column is
not in the base `CREATE TABLE`, so a fresh store and an old one each run
the patch exactly once. Putting it in the base schema instead would have
needed a guard on the `ALTER`s for no gain.

The same patch drops `notes_id`, the index on a note's GitLab id, and the
base schema stops creating it. Andi's decision, raised by the record-table
session: 8.3 MB on the real store, and nothing in the binary or the skill
queries looks a note up by id, since notes are keyed by position. `DROP
INDEX IF EXISTS` is repeatable, so a fresh store, which never had it, runs
it as a no-op.

The patch ends with `ANALYZE`, and that becomes the rule for any patch that
adds an index: the real store had no `sqlite_stat1`, and without it the
planner starts from the `kind` prefix of a primary key for every query shape
and walks half the table. Found while testing: `ANALYZE` records nothing
for an empty table, and a fresh store is empty when its patches run, so the
patch alone would leave every new store without statistics for good.
`closeSqliteStore` therefore ends with `PRAGMA optimize` (10 ms; re-analyses
only what changed enough to matter), which point 3 of the plan had put with
the views patch.

Verified on the 664 MB copy: migration 0.7 s including `ANALYZE`, both
indexes in `sqlite_stat1`, `WHERE ref = ?` on either table planned as an
index search, a 586-note thread counted by ref in 3 ms.

Pinned by "ref names the row in GitLab notation" (fresh store) and the
patch-2-store assertions in "a store at the old schema loses
has_discussion" (migration path, where `ANALYZE` has rows to see).

## 2026-09-03T13:15+00:00 — decision: how do agents query the store?

**Decision.** Schema patch 4 adds seven views (`view_tickets`, `view_mrs`,
`view_ticket`, `view_mr`, `view_notes`, `view_links`, `view_people`) and the
`ghc-gitlab` skill is rewritten around them, with detailed recipes in an
on-demand `queries.sql`. The thread views render each row's `text` in SQL
(heading line, blank line, body); the column is named `text`, not `body`,
and the raw body stays in `view_notes`. No `md` column beside a raw body:
`SELECT *` would then return every note twice.

**Reason.** 415 store queries from the local session logs and a week of
remote use (`tmp/jq-usage.md`): agents read sqlite3's default output raw
in 90–95 % of calls, never pipe into `jq`, use `-json` in 15 calls (9 read
raw), push shaping into SQL (`substr` in a fifth of queries), and leave SQL
only for search-with-snippet and per-record fan-out. The recurring
hand-written pieces were the record header (6×), the note-author join
(15+×), snippet extraction (3×) and thread rendering in Python. Output
shape measured on a 586-note thread: default 238 KB, `-json` 258 KB,
`-markdown` 38.7 MB, `-box` 49 MB (padding of multi-line bodies), so the
rendered column is what makes plain output usable for threads.

Verified on a copy of the real store: full migration from an unpatched
store (patches 1–4) 2.7 s including `--clear-timestamp`; thread of !15899
(586 notes) 7 ms; `view_tickets` by ref, author and state each use an
index; `view_links WHERE target_ref = …` scans the system notes, 2 s, the
known cost that would justify a materialised links table later. 58/58
tests.

Files: `src/FetchGitLab/Store/Schema/Views.hs` (new),
`src/FetchGitLab/Store/Schema.hs`, `fetch-gitlab.cabal`, `test/Main.hs`,
`agent-summary.md`, `.ai/summary/Schema.md`. Plan: `tmp/skill-view-plan.md`.

## 2026-09-18T08:30+00:00 — decision: job logs: how is a log tied to its job, and what is stored?

**Decision.** `--job-log JOB_ID` stores one log per job in `job_logs (log_id,
job_id UNIQUE REFERENCES jobs(id) ON DELETE CASCADE, raw_log TEXT)`, schema
patch 5. The log is always stored with terminal control stripped
(`FetchGitLab.JobLog.stripControlChars`); there is no option to keep it as
sent. Three things follow from the foreign key:

- `writeJob` changed from `INSERT OR REPLACE` to an upsert. Measured in
  sqlite 3.46: a replace on `jobs` deletes the old row, the cascade fires,
  and the log is gone — so every `--pipelines` refresh would have wiped the
  logs of that merge request. The upsert also stops `job_row` changing on
  every rewrite.
- A trigger `jobs_delete_log` repeats the cascade. `foreign_keys` is per
  connection and off by default in the `sqlite3` shell, which is where a job
  is most likely to be deleted; nothing in the binary deletes one.
- The job must be in the store before its log can be. `fetchJobLog` checks
  first and aborts with the `--pipelines` hint rather than fetching the job
  itself: a job object does not name the merge request its pipeline row
  would have to be filed under.

**Stripping.** Escape sequences (CSI, OSC, short forms), then per line only
the text after the last carriage return, then remaining control characters
except tab. Trailing CRs are dropped before the last-CR rule: the sed recipe
the skill used to give (`s/.*\r//`) empties every CR LF line. Newlines are
never touched, so line numbers match GitLab's.

**Why only the cleaned log, and why TEXT.** Both variants were built and
measured on job 2589581 (`ghc/ghc!16366`, a failed Windows job): 4.82 MB and
54265 lines as sent, 25675 of them carrying control bytes; 4.79 MB cleaned,
with none. A `--control-chars` flag that stored the bytes as sent was
dropped, because the log as sent is not text. That one holds a NUL, and as
`TEXT` every SQL string function stopped at it (`length()` gave 4818240 of
4820695 bytes, the shell printed 38 lines fewer) although every byte was
stored. As a `BLOB` that was fixed, but `LIKE` never matches a BLOB and
every query needed a `CAST`, which is a trap laid for each reader to serve a
variant almost nobody wants. Storing only the cleaned log makes the column
honest `TEXT`: `grep`, `LIKE`, `instr` and `substr` just work. The log as
sent is one request away at `/projects/:id/jobs/:job_id/trace`.

**Not done.** No fetch time is recorded, so a log fetched while its job was
running cannot be told from a final one except through the job's status.
Cleaning in SQL (store raw, clean in a view) was started as a prototype and
abandoned unfinished: stock SQLite has no regex replace and `instr` has no
offset, so it would have been a split-into-lines-then-recurse construction,
run on every read. Compression was considered and dropped: stock SQLite has
no compressed tables (ZIPVFS is commercial, `sqlite-zstd` and `compress.c`
are loadable extensions), and the skill reads the store with the plain
shell, which could not read a compressed log back.

**Files.** `JobLog.hs` (new), `Options.hs`, `Fetch.hs` (`fetchJobLog`),
`Store/Class.hs`, `Store/Sqlite.hs`, `Store/Schema/Pipeline.hs`
(`jobLogStatements`), `Store/Schema.hs`; the `oldStoreLosesHasDiscussion`
fixture now really applies patch 1, which it only claimed before.

## 2026-09-18T09:10+00:00 — decision: how long is CI data kept, and what is the unit of expiry?

**Decision.** `pipelines`, `jobs` and `job_logs` carry `expire_at`; every
write of a row sets it to now + one month, and the start of a fetching run
removes what has passed (`storePurgeExpired`, `Purged`). The retention period,
the expiry expression and "now" are SQL, defined once as `retentionInterval` /
`expirySql` / `nowSql` in `Store.Schema.Pipeline`, in a fixed-width UTC format
(`2026-10-18T08:50:20Z`) so a text comparison sorts. `encodeTime` is
deliberately not reused: it trims the fraction and does not sort
chronologically.

**The unit of expiry is the merge request's pipeline set.** Fetching a job's
log extends — never shortens — every pipeline of the `(kind, iid)` the job's
pipeline belongs to, and every job of those pipelines. Two reasons. A log is
deleted with its job (cascade plus `jobs_delete_log`), so a log fetched on day
29 of its job's life would be gone on day 30 whatever its own date said.
And renewing only the one job or the one pipeline would leave a merge request
holding a partial set, which reads as "this merge request ran one pipeline"
rather than as "the rest expired"; `--pipelines MR` is the unit a fetch works
in, so it is the unit expiry works in.

**One call site.** The purge runs in `Fetch.run` only, after the store is open
and logged and before the token is read, so it is under the store lock, its
result can be logged (info when something went, trace otherwise), and a reader
opening the store deletes nothing. `--clear-timestamp` explicitly does not
purge: it is the command a damaged store is repaired with.

**Order and counting.** Logs, then jobs — which take their own logs by cascade
and trigger — then the pipelines that have no job left: jobs reference
pipelines with no `ON DELETE` action and the binary enforces foreign keys, so
deleting a pipeline under a live job would fail the transaction. An expired
pipeline with an unexpired job therefore stays, which is the safe direction.
Counts are the difference of `count(*)` before and after, because `changes()`
counts neither a cascade nor a trigger. Afterwards, and only if something
went, `commits` and `runners` lose the rows no job refers to any more; `users`
is never touched, being shared with the records and notes. The purge also
drops the in-memory runner intern cache, whose row ids it may have deleted and
which SQLite hands out again. No `VACUUM`: the pages are reused by what the
store grows into next.

**Schema: patch 5 was edited, not followed by a patch 6.** Patch 5 was
uncommitted and no permanent store had run it — the real store was checked
read-only and is at `schema_patch_version` 4 — so the whole unreleased feature
set stays one patch rather than two. Patch 5 now creates `job_logs` with
`expire_at TEXT NOT NULL`, creates the trigger, adds the column to `pipelines`
and `jobs`, and dates the rows a store already holds. Consequences:

- `expire_at` comes *before* `raw_log` in `job_logs`. A log is megabytes and
  spills into overflow pages, and SQLite reaches a column behind it only by
  walking that chain; the purge reads `expire_at` of every row.
- The patch is no longer repeatable, like patch 3: `ADD COLUMN` runs once, and
  the column is in neither the base schema nor patch 1 — which is why it must
  not be added to `pipelineSchemaStatements`, or a fresh store would fail on a
  duplicate column.
- `ADD COLUMN` cannot be `NOT NULL` without a constant default and `expirySql`
  is not constant, so on `pipelines` and `jobs` the column is nullable and
  arrives NULL. NULL means "not expired" to the purge, never "delete", and the
  two `UPDATE`s give the rows a store already holds a month from the migration
  rather than leaving them immortal.

**Verified.** 77 tests, eight of them new, moving time by rewriting
`expire_at` through a raw connection rather than injecting a clock. Live
against `ghc/ghc`: `--pipelines 16366` wrote 4 pipelines and 68 jobs at
`2026-10-18T08:50:20Z`, `--job-log 2589581` wrote the log and pulled all 72
of those rows up to its own second; with everything set to 2000 the next run
logged `Removed expired: 4 pipelines, 68 jobs, 1 job log` and left
`pipelines`, `jobs`, `job_logs`, `runners` and `commits` empty with `users`
untouched, and a following `--pipelines 16366` refilled it.

**Also done here.** The `(Nothing, Nothing)` branch of `run` is outlined as
`fetchTicketsAndMrs`, so the dispatch is three one-line alternatives.

**Files.** `Store/Schema/Pipeline.hs` (patch 5, the three SQL definitions),
`Store/Schema.hs` (patch list haddock), `Store/Class.hs` (`storePurgeExpired`,
`Purged`, `describePurged`), `Store/Sqlite.hs` (the writes, the purge,
`ciCounts`), `Fetch.hs` (purge at startup, `fetchTicketsAndMrs`),
`test/Main.hs`, `README.md`, `agent-summary.md`,
`skill/ghc-gitlab/Pipelines.md`, `.ai/summary/{store,Schema,fetch,modules}.md`.
