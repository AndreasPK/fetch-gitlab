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
