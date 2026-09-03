# The store

`Store.Class` is the interface, `Store.Sqlite` the only backend,
`Store.Backend` names and opens one. Tables are in `Store.Schema` and
`Store.Schema.Pipeline`; the lift/splice machinery in `Store.Schema.Types`.
Schema versioning is [Schema.md](Schema.md).

## Where things are

- `Record` (`FetchGitLab.Store`): `recordKey` is the `iid`, `recordKind`
  is `ticket` or `mr`. One handle serves both kinds; the instance at the
  call site decides which.
- `StoreBackend`: `storeLoad`, `storeLoadWithoutNotes`, `storeSave` with
  the changed keys, `storeLookup`, `storeWritePipelines`.
- `Backend` (`Options`) is a one-constructor type on purpose; its haddock
  says how a second backend is added.
- `splitObject` / `spliceObject` with a `LiftSpec` split an object into
  interned tables plus a verbatim `rest`; `liftedKeys` remembers what was
  removed.

## Invariants

- `storeSave` writes only the keys it is given and nothing else. That is
  what makes a checkpoint constant-cost as the store grows; see log
  2026-09-03 "changed-key checkpoints".
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

## Pipelines

- Pipelines keyed by GitLab id and carrying `(kind, iid)`; jobs by an
  autoincrement row with the GitLab id UNIQUE only. A runner is interned per
  observed state; comment in Pipeline.hs. Rewriting a merge request's
  pipelines replaces them ("rewriting pipelines replaces rather than
  duplicates").
