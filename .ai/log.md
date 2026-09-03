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
