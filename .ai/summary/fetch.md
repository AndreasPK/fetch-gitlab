# Fetching

`FetchGitLab.Fetch`. The network side is [network.md](network.md), the store
side [store.md](store.md), the lock [lock.md](lock.md).

## Where things are

- `run` — the order: lock, `storePurgeExpired`, `readToken`,
  `lookupProject` through the one *checked* `runGitLabWithManager` call, then
  one of three branches: `fetchTicketsAndMrs` (`storeLatestUpdate` and
  `fetchSince` per kind, `fetchRecords` per kind, `fetchDiscussions` unless
  `--no-notes`), `fetchMrPipelines` or `fetchPipelinesSince` for
  `--pipelines`, `fetchJobLog` for `--job-log`.
  `--clear-timestamp` is `FetchGitLab.ClearTimestamp`.
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
  failure aborts. Jobs always come with a pipeline (one request each: a page
  holds 100, GHC's nightly has 73).
- MR mode writes once at the end; `--since` writes per pipeline, summary in
  a second transaction — so `pipelineIsCurrent` must require the summary's
  `pipeline_updated_at` to match when `--with-summary`, or an interrupted run
  strands a pipeline without one. The stamp is the listed `updated_at`,
  never a later one, as with discussions.
- `pipelineIsCurrent` trusts `updated_at` only on a final status: it moves
  with the pipeline's own status, not its jobs'. Log 2026-09-24 "pipelines
  created since".
- The purge is the only thing that deletes from a store, it runs before the
  token is read, and `--clear-timestamp` deliberately does not do it — that
  is the command a damaged store is repaired with. See [store.md](store.md).
- `fetchJobLog` asks `storeHasJob` before the request: the log needs its
  job row, and nothing in a job says which merge request to fetch it under.
- The trace endpoint answers with text, so `fetchJobLog` goes through
  `gitlabGetByteStringResponse`, which never returns `Left`. Its `classify`
  turns a challenge (HTTP 200, HTML) into the `Left` that `orChallenge`
  raises; without it an interstitial is stored as the log.

## Traps

- `updated_after` is inclusive, so every page repeats its anchor: dedupe by
  `iid` within the run, and expect the "already current" count to be 1, not 0.
- A full page stamped with one instant cannot advance the anchor.
  `fetchRecords` steps past and logs; the next run collects what it skipped.

## Constraints

- Heap cap `-M1G` (cabal file) is no longer a design constraint — a run's
  memory does not grow with the store — but it is kept as a leak detector.
