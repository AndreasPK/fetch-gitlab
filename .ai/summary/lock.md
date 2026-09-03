# Locking

`FetchGitLab.Lock`: `withStoreLocks`, `LockInfo`, `lockPath`. Both a fetch
and `--clear-timestamp` take it; it never waits.

## Why it exists

- Not to prevent data loss. Since the write-through store, every write
  states one thing the run learned and is its own immediate transaction, so
  concurrent runs can only duplicate work; see log 2026-09-03
  "write-through store". The lock stops two runs spending hours on the same
  project and doubling the request rate against one token, and lets the
  second name who is in the way.
- Hence no `PRAGMA locking_mode = EXCLUSIVE`: a reader must be able to query
  the store while a run writes it.

## Invariants

- The lock is on `<store>.lock`, never on the store; `lockPath`'s haddock
  says why. The lock file is only created, locked and rewritten in place.
- The file's contents (`LockInfo`) are for the error message only. A
  leftover file is not a stale lock; the OS releases the real one.

## Traps

- GHC refuses to open a file twice for writing in one process, so an
  `openFile` "resource busy" *is* a held lock, and the holder must be read
  through the handle already open. `readLockInfo`'s haddock.
- Because of that, a same-process nested lock never reaches the OS. The
  real cross-process case is tested by re-running the test executable with
  `--hold-lock` ("another process is excluded, named, and survives a
  rewrite").
