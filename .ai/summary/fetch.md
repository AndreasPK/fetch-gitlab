# Fetching

`FetchGitLab.Fetch`. The network side is [network.md](network.md), the store
side [store.md](store.md), the lock [lock.md](lock.md).

## Where things are

- `run` — the order: lock, `readToken`, `fetchSince` per kind,
  `lookupProject` through the one *checked* `runGitLabWithManager` call,
  `fetchRecords` per kind, then `fetchDiscussions` unless `--no-notes`.
  `fetchPipelines` is the `--pipelines` branch; `--clear-timestamp` is
  `FetchGitLab.ClearTimestamp`.
- `fetchRecords` — one request per page of `recordsPerPage`, written
  before the next is asked for. Its haddock explains the `updated_at`
  anchoring; do not replace it with numbered pages.
- `fetchDiscussions` — newest entry first, `storeSave` every
  `checkpointEvery`, `forgetWritten` after each.
- `waitOutChallenge` wraps both GitLab runners; see network.md.

## Invariants

- The start point is `latestUpdate` of the records themselves, never a
  stored timestamp. Nothing but `--since` can move it back; a run that
  fetches too little has a watermark past the gap, permanently.
- Every request after the first goes through `runGitLabWithManagerUnchecked`
  ([vendored-gitlab-haskell.md](vendored-gitlab-haskell.md)). The checked
  runner adds a `/version` request per action, which doubles the note phase.
- A run loads with `storeLoadWithoutNotes`; a `Kept` discussion means "in
  the store, not read in" and must never be written back as empty. See
  `Discussion` in `FetchGitLab.Store`; pinned by
  "rewriting an unloaded entry keeps its notes".
- `forgetWritten` is sound only because `storeSave` was given exactly those
  keys. Keep the two in step.
- Pipelines are fetched as raw `Value`, never through typed models, and any
  failure aborts; there is no staleness bookkeeping for them.

## Traps

- `updated_after` is inclusive, so every page repeats its anchor: dedupe by
  `iid` within the run, and expect `alreadyCurrent` to be 1, not 0.
- A full page stamped with one instant cannot advance the anchor.
  `fetchRecords` steps past and logs; the next run collects what it skipped.

## Constraints

- Heap cap `-M1G` (cabal file). Notes out of memory fits `ghc/ghc` in
  ~850 MiB; with notes it needs ~2 GB. See log 2026-09-03 "notes out of
  memory".
