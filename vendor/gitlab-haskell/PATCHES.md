# Local patches to gitlab-haskell 1.4.0.0

Unmodified 1.4.0.0 from Hackage, plus the changes below. `cabal.project` in the
repository root lists this directory, so the build uses this copy rather than
the released one.

This is a workaround, not a fork worth keeping. Patches 1 to 3 are upstream
bugs and `repro/` holds a standalone reproducer written for filing them.
Patches 4 and 5 are additions rather than fixes: they give a caller control the
library does not otherwise offer, without changing what the existing functions
do. Drop this directory and the `cabal.project` entry once a release carries
the fixes and something equivalent to the additions.

To see exactly what changed:

```
tar xf ~/.cabal/packages/*/gitlab-haskell/1.4.0.0/gitlab-haskell-1.4.0.0.tar.gz -C /tmp
for f in src/GitLab.hs src/GitLab/Types.hs src/GitLab/API/Issues.hs \
         src/GitLab/API/MergeRequests.hs src/GitLab/WebRequests/GitLabWebCalls.hs; do
  diff -u /tmp/gitlab-haskell-1.4.0.0/$f $f
done
```

## 1. A page that fails to decode no longer discards the rest of the collection

`gitlabHTTPMany`, in `src/GitLab/WebRequests/GitLabWebCalls.hs`.

Upstream decoded each page as a whole. When that failed it wrote the error to
stderr and returned `Right accum` — the pages gathered so far, reported as a
**success**, with every remaining page abandoned. One record the library
mistypes therefore silently swallowed the rest of the collection, and the
caller had no way to tell a truncated result from a complete one.

Measured against `ghc/ghc`: two merge requests out of 2353 carry a null
`source_project_id`, the first of them on page 6 of 24. The call returned 500
merge requests as a success and dropped 1853 of them, 79%.

That is worse than it sounds for an incremental fetcher. `fetch-gitlab` derives
the next run's `updated_after` from the newest record it now holds, and a
truncation keeps precisely the newest records — so the new watermark is past
everything that was dropped and no later run ever asks for those records again.
A deterministic library failure became permanent silent data loss.

The page is now decoded to `[Value]` first and each element decoded on its own.
An element that cannot be read is reported on stderr and skipped, paging
continues to the end, and only that one record is lost. A body that is not a
JSON array at all has no elements to salvage, so that raises a `GitLabError`
through the `GitLab` monad rather than being reported as success.

## 2. `merge_request_source_project_id` is nullable

`src/GitLab/Types.hs`, changed from `Int` to `Maybe Int`.

GitLab returns null when the merge request's source project has been deleted;
`ghc/ghc!16018` and `ghc/ghc!3745` are live examples. GitLab's REST
documentation types the field as a plain integer and says nothing about
nullability, but its GraphQL schema is explicit: `MergeRequest.sourceProjectId`
is nullable, `targetProjectId` is not. `merge_request_target_project_id` is
therefore left as `Int`; patch 1 is what keeps an unexpected null there from
costing more than the one record.

## 3. A single result that fails to decode is an error, and says what came back

`gitlabHTTPOne`, same file, which went through `parseOne`:

```haskell
parseOne bs = case eitherDecode bs of
  Left _err -> Nothing
  Right x -> Just x
```

The error was discarded outright — not even written to stderr, unlike the
paginated path — so `Right Nothing` meant either "the server does not have
this" or "the library could not read it", indistinguishable and undiagnosable.

`gitlabHTTPOne` now decodes for itself and raises a `GitLabError` when it
cannot. `Nothing` is left meaning only "the server does not have this", which
is what a caller assumes it means: a genuine absence is a 404, and a 404 is not
a success status, so it returns `Left` before reaching the decode at all.
`parseOne` had no other callers and was not exported, so it is gone.

The error message names what arrived instead, via `notJson`. The case worth
naming is an anti-bot interstitial, which `gitlab.haskell.org` served us during
this work after a few thousand requests: those come back with **HTTP 200** and
an HTML body, so every check short of parsing says the request succeeded. With
the old behaviour a run reported

```
GitLab request failed: GitLabError "no such project: ghc/ghc"
```

which is a long way from the truth and sends whoever reads it after entirely
the wrong problem. It now reports

```
GitLab request failed: GitLabError "the server answered /version with an
anti-bot interstitial (the request never reached the API) rather than JSON:
Unexpected \"<!doctype html>...\""
```

The challenge cleared on its own once traffic dropped, so it is throttling
rather than a ban — but it is worth being able to recognise, because the volume
that triggers it is well within what a cold run makes.

A body that is JSON but not the shape the library expects is named separately,
since "the server answered with something rather than JSON" is its own kind of
misleading when the server answered with JSON.

## 4. A collection can be fetched a page at a time

`gitlabGetPage` in `src/GitLab/WebRequests/GitLabWebCalls.hs`, and
`projectIssuesPage` and `mergeRequestsWithPage` in the two API modules.

`gitlabGetMany` pages to the end of a collection before it returns anything.
For a project the size of `ghc/ghc` that is a few hundred requests and several
minutes inside one call, with no way to see how far it has got, nothing written
if it is interrupted, and no say in where the next page starts.

`gitlabGetPage` returns a single page and leaves the rest to the caller. A page
shorter than the number asked for is the last one. The decoding is shared with
`gitlabHTTPMany`, so patch 1 applies to both.

Having a say in where the next page starts is the part that matters. Numbered
pages over a collection that is being edited underneath you are not safe to
stop halfway through, and not entirely safe even when you don't: sort by
`updated_at` ascending and a record edited mid-fetch moves to the end, shifting
a neighbour out of the numbering unseen. `fetch-gitlab` uses this to page on
`updated_after` instead — each request asks for what comes after the newest
record it has — which has neither problem and costs the same number of
requests.

## 5. The token check does not have to run before every action

`runGitLabWithManagerUnchecked` in `src/GitLab.hs`.

`runGitLabWithManager` asks the server for `/version` before running the action
it is given, to check the token. That is reasonable once. It is not reasonable
per action, and a program that runs one action per record — which is what
fetching a discussion for each issue is — pays a second request for every one
it wanted.

Measured on `ghc/ghc`: the discussion phase is around 28,000 requests, so the
version checks were another 28,000. At two requests a second that is four extra
hours of fetching, and twice the load on the server, to re-establish something
that cannot have changed since the run started.

The new function is the same minus the check. `runGitLabWithManager` is
unchanged and `fetch-gitlab` still calls it once at the start, so a bad token
is still reported immediately rather than as a wall of failures.
