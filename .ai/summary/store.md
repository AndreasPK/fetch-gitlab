# The store

`Store.Class` is the interface, `Store.Sqlite` the only backend,
`Store.Backend` names and opens one. Tables are in `Store.Schema` and
`Store.Schema.Pipeline`; the lift/splice machinery in `Store.Schema.Types`.
Schema versioning is [Schema.md](Schema.md).

## Where things are

- `Record` (`FetchGitLab.Store`): `recordKey` is the `iid`, `recordKind`
  is `ticket` or `mr`. One handle serves both kinds; the instance at the
  call site decides which, or a `Proxy` where there is no record to take it
  from.
- `StoreBackend` writes: `storeWriteRecords`, `storeWriteDiscussion`,
  `storeWritePipelines`, `storeWriteJobLog`, `storeClearDiscussionStamps`,
  `storePurgeExpired`.
  Asks: `storeHasJob`, `storeDiscussionPlan`, `storeRecordCount`, `storeLatestUpdate`,
  `storeRecordVersions`. Reader's view: `storeLoad`, `storeLookup`,
  `Entry`, `Store`.
- `Backend` (`Options`) is a one-constructor type on purpose; its haddock
  says how a second backend is added.
- `splitObject` / `spliceObject` with a `LiftSpec` split an object into
  interned tables plus a verbatim `rest`; `liftedKeys` remembers what was
  removed.

## Invariants

- **A write states one thing the caller just learned, and nothing else.** A
  record write never touches `discussion_updated_at` or the note rows; a
  discussion write never touches the record. Nothing writes a snapshot back,
  so concurrent writers cannot undo each other. See log 2026-09-03
  "write-through store".
- Every write is one `BEGIN IMMEDIATE` transaction (`withImmediateTransaction`
  in Sqlite.hs, whose haddock says why a deferred `BEGIN` plus `busy_timeout`
  is not enough). Nothing may take the deferred `withTransaction`.
- "Fetched" is `discussion_updated_at IS NOT NULL`; there is no
  `has_discussion` column since schema patch 2.
- Interned objects are keyed on their exact JSON. Two copies of a user with
  different fields are two rows; never merge them.
- Split and splice are inverses on every fixture and the real store
  ("splitting and splicing are inverse"). An absent field and an empty list
  are different after splicing; the staleness check depends on it
  ("an absent field is not invented").
- Queryable columns are `GENERATED ... VIRTUAL` over `rest`. Real columns
  doubled the size of the store; comment in Schema.hs.
- Notes are keyed `(kind, iid, position)`, never by GitLab's note id;
  comment above the `notes` table.
- `ref` (`#123` / `!123`, schema patch 3) on `records` and `notes` is a
  generated, indexed name for queries, not a key: Haskell never reads or
  writes it, and the junction and pipeline tables do not have it.
- `discussion_updated_at` and the generated `updated_at` are compared as
  text, so both must come from `encodeTime` (Sqlite.hs), which trims the
  fraction (`.550Z` → `.55Z`); a second encoder makes every discussion read
  as stale ("both timestamp columns are written by one encoder"). The text
  does not sort chronologically: `MAX`/`ORDER BY` on it are off by under a
  second. Log 2026-09-03 "timestamps round the same way on every path".

## Pipelines

- Pipelines keyed by GitLab id and carrying `(kind, iid)`; jobs by an
  autoincrement row with the GitLab id UNIQUE only. A runner is interned per
  observed state; comment in Pipeline.hs. Rewriting a merge request's
  pipelines replaces them ("rewriting pipelines replaces rather than
  duplicates").
- `job_logs` (patch 5) holds one log per job, keyed on the job's GitLab `id`,
  not `job_row`. A log goes with its job twice over: `ON DELETE CASCADE` and
  the `jobs_delete_log` trigger, the trigger being for connections without
  `PRAGMA foreign_keys` — the `sqlite3` shell ("deleting a job deletes its
  log, foreign keys enforced or not").
- **Never write `jobs` with `INSERT OR REPLACE`.** A replace deletes the old
  row, which cascades to the log; `writeJob` is an upsert ("refreshing
  pipelines keeps a job's log"). Any future table hanging off `jobs` inherits
  this. Log 2026-09-18 "job logs".
- Expiry is SQL, not Haskell: `expirySql`/`nowSql`/`retentionInterval`
  (Pipeline.hs) are the only definitions, so writes, patch 5 and the purge
  cannot disagree. Fixed width and UTC, so it sorts — unlike `encodeTime`,
  which must not be reused for it. NULL means "not expired". `job_logs` puts
  `expire_at` before `raw_log`: a column behind a megabyte one is reached by
  walking overflow pages, and the purge reads every row's.
- `storePurgeExpired` has **one** call site, the start of `Fetch.run`, and
  deletes logs, then jobs, then pipelines *with no job left*: jobs reference
  pipelines with no `ON DELETE` action. Counted by `count(*)` before and
  after, since `changes()` sees neither cascade nor trigger; it also drops
  the runner intern cache, whose row ids it may have deleted.
- `storeWriteJobLog` extends the expiry of the whole merge request — every
  pipeline of `(kind, iid)` and every job of those — never shortening one:
  the unit of fetching is the unit of expiry. Log 2026-09-18 "expiry".
- `raw_log` is `TEXT` only because a log is always stored cleaned
  (`JobLog.stripControlChars`). A log as sent can hold a NUL, where SQL stops
  reading a text value; storing one would need a BLOB, which `LIKE` never
  matches. Do not add a "keep it raw" option without changing the type.
