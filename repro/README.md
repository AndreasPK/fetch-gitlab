# Reproducer: gitlab-haskell 1.4.0.0 — nullable `source_project_id` + swallowed decode errors

Standalone reproducer for two independent bugs in gitlab-haskell 1.4.0.0.
The first is a data bug that triggers the second; the second is the
dangerous one and is worth fixing on its own.

## Bug A: `source_project_id` typed `Int`, but GitLab returns `null`

`src/GitLab/Types.hs:962`:

```haskell
merge_request_source_project_id :: Int,
merge_request_target_project_id :: Int,
```

GitLab returns `"source_project_id": null` when a merge request's source
fork has been deleted. Decoding such an MR fails:

```
Error in $['source_project_id']: parsing Int failed, expected Number, but encountered Null
```

Live examples in `ghc/ghc` (project id 1 on gitlab.haskell.org): MR !16018
and !3745. `source_project_id` should be `Maybe Int`. On documentation:
the REST API docs type both fields as plain `integer` with no nullability
marking (the observed `null` contradicts them), but GitLab's GraphQL
schema is explicit — `MergeRequest.sourceProjectId` is nullable
([`Int`](https://docs.gitlab.com/api/graphql/reference/#mergerequest-sourceprojectid))
while `targetProjectId` is non-null
([`Int!`](https://docs.gitlab.com/api/graphql/reference/#mergerequest-targetprojectid)).
So making `target_project_id` a `Maybe` too would be defensive only, and
other non-`Maybe` `MergeRequest` fields deserve the same audit.

## Bug B: decode failures reported as success

Two spots in `src/GitLab/WebRequests/GitLabWebCalls.hs`:

1. `parseOne` (used by `gitlabGetOne`, so e.g. `mergeRequest`) maps any
   JSON parse error to `Nothing` — an MR that exists but fails to decode
   is indistinguishable from an MR that does not exist.

2. `gitlabHTTPMany` (used by `gitlabGetMany`, so e.g. `mergeRequests`,
   `mergeRequestsWith`) handles a parse error by printing it to **stderr**
   and returning `Right accum`:
   - the caller cannot distinguish a truncated result from a complete one;
   - the diagnostic is not available programmatically;
   - all remaining pages are abandoned, so one bad record among 100 drops
     its whole page *and every page after it*.

Measured against `ghc/ghc` with `updated_after=2025-08-16T09:04:49Z`
(as of 2026-08-16): 2353 matching MRs across 24 pages; the first
undecodable record sits on page 6, so the call returns 500 MRs as a
success and silently drops 1853 (79%).

This is particularly nasty for incremental fetchers: the truncation keeps
exactly the *newest* records, so a watermark derived from the result is
newer than every dropped record and no later run ever re-requests them.
A deterministic decode failure becomes permanent silent data loss.

Bug B is not confined to merge request lists.  Every paginated endpoint
goes through `gitlabHTTPMany` — including notes: `issueNotes` and
`mergeRequestNotes` (src/GitLab/API/Notes.hs) call `gitlabGetMany`.  A
discussion longer than 100 notes spans pages, so a single undecodable
note silently returns a partial discussion as success (`Note` has
non-`Maybe` fields with the same latent shape, e.g.
`note_author :: Owner`).  In `ghc/ghc`, discussions with several hundred
notes exist, so multi-page discussions are ordinary, not a corner case.

## Running

```
cabal run repro              # steps 1+2: fetch ghc/ghc !16018 (2 requests, anonymous)
cabal run repro -- --list    # + step 3: silent list truncation (~7 requests)
cabal run repro -- --offline # step 1 only, no network, uses fixtures/mr-16018.json
```

Set `GITLAB_TOKEN` to a gitlab.haskell.org read token to authenticate the
requests if anonymous access hits rate limiting.

Exit code 1 means at least one bug reproduced; 0 means all behaved.

## Observed output (2026-08-16, gitlab-haskell 1.4.0.0, GHC 9.10.3)

```
== 1. decode the JSON of ghc/ghc !16018 as MergeRequest ==
   response has "source_project_id": null
   BUG A (field type): Error in $['source_project_id']: parsing Int failed, expected Number, but encountered Null
== 2. fetch the same MR through the typed API (mergeRequest) ==
   BUG B (swallowed error): returned (Right Nothing), i.e. the MR
   does not exist - parseOne discarded the JSON parse error.
== 3. list ghc/ghc MRs updated after 2025-08-16 (contains !16018) ==
   (lines tagged [gitlab-haskell] are the library writing to stderr;
    the caller has no programmatic access to that error)
[gitlab-haskell] JSON decode error for /projects/1/merge_requests (page 6): Error in $[21]['source_project_id']: parsing Int failed, expected Number, but encountered Null
[gitlab-haskell] Raw response body: "[{\"id\":18489,...
   returned as success: 500 merge requests
   BUG B (silent truncation): !16018 matches this query, but the
   page containing it failed to decode, so that page and all later
   pages were dropped - yet the call reported success.  At the
   time of writing this drops 1853 of 2353 matching MRs (79%).
```

`fixtures/mr-16018.json` is the verbatim response of
`GET https://gitlab.haskell.org/api/v4/projects/1/merge_requests/16018`
(public data, fetched anonymously on 2026-08-16).
