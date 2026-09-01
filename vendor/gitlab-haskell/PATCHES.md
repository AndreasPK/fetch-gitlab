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
         src/GitLab/API/MergeRequests.hs src/GitLab/WebRequests/GitLabWebCalls.hs \
         src/GitLab/SystemHooks/GitLabSystemHooks.hs; do
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

The remaining sharp edge is that a skipped record is recorded only on stderr,
which does not reach a caller's logger: a store can end up with a gap in it that
nothing but the terminal ever mentioned. Returning the count of what was skipped
would close that, and has not been done.

## 2. `merge_request_source_project_id` is nullable

`src/GitLab/Types.hs`, changed from `Int` to `Maybe Int`.

GitLab returns null when the merge request's source project has been deleted;
`ghc/ghc!16018` and `ghc/ghc!3745` are live examples. GitLab's REST
documentation types the field as a plain integer and says nothing about
nullability, but its GraphQL schema is explicit: `MergeRequest.sourceProjectId`
is nullable, `targetProjectId` is not. `merge_request_target_project_id` is
therefore left as `Int`; patch 1 is what keeps an unexpected null there from
costing more than the one record.

## 3. `Nothing` means the server sent nothing, not that we failed to read it

`gitlabHTTPOne`, same file, which went through `parseOne`:

```haskell
parseOne bs = case eitherDecode bs of
  Left _err -> Nothing
  Right x -> Just x
```

The error was discarded outright — not even written to stderr, unlike the
paginated path — so `Right Nothing` meant either "the server does not have
this" or "the library could not read it", indistinguishable and undiagnosable.

`gitlabHTTPOne` now decides `Nothing` from the response rather than from a
failure to read it. `Nothing` is returned when the server said there is no
payload: an explicit `204 No Content`, or any 2xx with an empty body. That is
the normal outcome of every `DELETE`, so the `Maybe ()` endpoints
(`deletePipeline`, `deleteMergeRequest'`, `deleteProjectArtifacts` and the rest)
are now right by construction rather than by accident — upstream reached the
same answer only because the empty body failed to decode.

A body that is there and cannot be read raises a `GitLabError` through the
`GitLab` monad, so it is reported as the failure it is instead of as an absence
that never happened. The decode is at `Maybe a`, so a JSON `null` body is
`Nothing` rather than a failure. `parseOne` had no other callers and was not
exported, so it is gone.

A 404 stays in `Left`. It is not a success status, so it never reaches any of
this — and folding it into `Nothing` would make "deleted it" and "it was not
there" the same value at every delete endpoint. GitLab also answers 404 for a
resource the token may not see, which is a third thing `Nothing` would erase.

The case this was first written for is an anti-bot interstitial, which
`gitlab.haskell.org` served us during this work after a few thousand requests:
those come back with **HTTP 200** and an HTML body, so every check short of
parsing says the request succeeded. Upstream reported that as

```
GitLab request failed: GitLabError "no such project: ghc/ghc"
```

which is a long way from the truth and sends whoever reads it after entirely
the wrong problem.

## 3a. Naming what came back

`notJson` and `GitLabChallengeError`, in the same file and in
`src/GitLab/Types.hs`.

Every path that raises for an unreadable body goes through `notJson`, so the
error says what arrived instead:

```
GitLab request failed: GitLabError "the server answered /version with an
anti-bot interstitial (the request never reached the API) rather than JSON:
Unexpected \"<!doctype html>...\""
```

A body that is JSON but not the shape the library expects is named separately,
since "the server answered with something rather than JSON" is its own kind of
misleading when the server answered with JSON.

An interstitial also gets its own constructor, `GitLabChallengeError`, rather
than only a recognisable message. A challenge is transient where every other
error in that type is not, so a caller can wait it out instead of failing — and
that is worth more than a message it would have to match on with a substring
search that the next wording change would break. The challenge cleared on its
own once traffic dropped, so it is throttling rather than a ban, but the volume
that triggers it is well within what a cold run makes.

This covers `gitlabHTTPOne`, `gitlabHTTPMany` and `gitlabGetPage` alike, so a
challenge on the project lookup, on a discussion or on a record page all reach
the caller as `GitLabChallengeError`.

The `/version` token check in `runGitLabWithManager` is the odd one out: it
reads `gitlabVersion`'s response itself rather than through the decoders. A
challenge there needs nothing extra -- it arrives as a 200 with an HTML body,
so `gitlabHTTPOne` raises `GitLabChallengeError` before the check reads
anything. What the check does read are the statuses that are not a success,
and there it kept only the status line -- `GitLabError "unexpected HTTP
status: 503 Service Unavailable"` -- and threw away the body, the part that
says whether that was the server, a proxy or a maintenance page. It now
reports through `unexpectedStatus`, which keeps the start of the body. Its
401 case also matched the reason phrase as well as the code, so a server that
words a 401 differently was reported as an unexpected status rather than as a
bad token; it now matches the code alone.

An interstitial under an error status is deliberately not a
`GitLabChallengeError`, there or anywhere else: a challenge is worth waiting
out precisely because the server claimed success while answering with
something else, and the same page under a 503 is an outage that has to fail
on the first try rather than be waited on.

## 4. A collection can be fetched a page at a time

`gitlabGetPage` in `src/GitLab/WebRequests/GitLabWebCalls.hs`, and
`projectIssuesPage` and `mergeRequestsWithPage` in the two API modules.

`gitlabGetMany` pages to the end of a collection before it returns anything.
For a project the size of `ghc/ghc` that is a few hundred requests and several
minutes inside one call, with no way to see how far it has got, nothing written
if it is interrupted, and no say in where the next page starts.

`gitlabGetPage` returns a single page and leaves the rest to the caller. A page
shorter than the number asked for is the last one. The decoding is shared with
`gitlabHTTPMany` through `decodePage`, so patch 1 applies to both.

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

## 6. The raw request layer is exposed

`GitLab.WebRequests.GitLabWebCalls` moved from `other-modules` to
`exposed-modules` in the cabal file. No code change.

The typed API covers a fraction of GitLab's endpoints — a merge request's
pipelines and a pipeline's jobs, which `fetch-gitlab --pipelines` needs, are
not among them — and the typed models drop any field they do not know, which
a store that keeps objects verbatim cannot accept. `gitlabGetMany` is
polymorphic in its `FromJSON` result, so an exposed request layer lets a
caller fetch any endpoint as raw `Value`s: every field kept, no vendored
model to maintain, and still through the library's session, retries and
pagination.
