# Fetching

`FetchGitLab.Fetch`. The network side is [network.md](network.md), the store
side [store.md](store.md), the lock [lock.md](lock.md).

## Where things are

- `run` — the order: lock, `readToken`, `storeLatestUpdate` then
  `fetchSince` per kind, `lookupProject` through the one *checked*
  `runGitLabWithManager` call, `fetchRecords` per kind, then
  `fetchDiscussions` unless `--no-notes`. `fetchPipelines` is the
  `--pipelines` branch; `--clear-timestamp` is `FetchGitLab.ClearTimestamp`.
- `fetchRecords` — one request per page of `recordsPerPage`, written
  before the next is asked for. Its haddock explains the `updated_at`
  anchoring; do not replace it with numbered pages.
- `fetchDiscussions` — works through `storeDiscussionPlan`, writing each
  discussion as it arrives; `progressEvery` only logs.
- `waitOutChallenge` wraps both GitLab runners; see network.md.

## Invariants

- A write states one thing the run learned. The stamp written with a
  discussion is the `updated_at` the plan gave, never the row's: a record
  that moved in between must stay stale, and the race costs one refetch.
  See log 2026-09-03 "write-through store".
- The start point is `storeLatestUpdate` of the records themselves, never a
  stored timestamp. Nothing but `--since` can move it back; a run that
  fetches too little has a watermark past the gap, permanently.
- Every request after the first goes through `runGitLabWithManagerUnchecked`
  ([vendored-gitlab-haskell.md](vendored-gitlab-haskell.md)). The checked
  runner adds a `/version` request per action, which doubles the note phase.
- A run holds a page of records and the plan, never the store: memory is
  O(page) + O(plan) whatever the project's history costs.
- Pipelines are fetched as raw `Value`, never through typed models, and any
  failure aborts; there is no staleness bookkeeping for them.

## Traps

- `updated_after` is inclusive, so every page repeats its anchor: dedupe by
  `iid` within the run, and expect the "already current" count to be 1, not 0.
- A full page stamped with one instant cannot advance the anchor.
  `fetchRecords` steps past and logs; the next run collects what it skipped.

## Constraints

- Heap cap `-M1G` (cabal file) is no longer a design constraint — a run's
  memory does not grow with the store — but it is kept as a leak detector.
