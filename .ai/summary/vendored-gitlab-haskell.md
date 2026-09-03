# The vendored gitlab-haskell

`vendor/gitlab-haskell`, a patched 1.4.0.0 built via `cabal.project`.
`PATCHES.md` there is the full account; `repro/` reproduces the bugs
standalone.

## Constraints

- Do not switch back to Hackage until a release carries the fixes below.
  The additions would then need a home in this package.
- `gitlabHTTPMany` once returned a truncated collection as success. With
  `updated_at`-anchored fetching that loss is permanent and silent (79% of
  merge requests, once). Any replacement for paging must fail loudly.

## What is patched

- `gitlabHTTPMany` decodes element by element and pages to the end.
- `merge_request_source_project_id` is `Maybe Int`; the target id is not.
- `parseOne` reports decode errors instead of reading as "not found".

## What is added

- `gitlabGetPage`, `projectIssuesPage`, `mergeRequestsWithPage`: one page.
- `runGitLabWithManagerUnchecked`: no `/version` check per action.
- `GitLabChallengeError`: a challenge is its own constructor.
- `GitLab.WebRequests.GitLabWebCalls` is exposed for raw `Value` fetches.
