---
name: ghc-gitlab
description: Query the local fetch-gitlab SQLite store for gitlab.haskell.org tickets, MR discussions and MR CI results. Used when asked about ghc issues or merge requests, or why an MR's CI pipeline failed.
---

# Querying a fetch-gitlab store

`fetch-gitlab` dumps `ghc/ghc`'s tickets and merge requests, with their
discussions, into `~/.fetch-gitlab/gitlab.db`. Open it read-only; never
write to a store you did not create. No file means no fetch has run yet:
say so rather than polling. Without `sqlite3`, Python's
`sqlite3.connect('file:PATH?mode=ro', uri=True)` runs the same SQL.

```
sqlite3 -readonly ~/.fetch-gitlab/gitlab.db "SELECT count(*) FROM view_tickets"
```

## Views

A record is named by `ref`: `#123` is a ticket, `!123` a merge request.

| view | one row per | columns |
|---|---|---|
| `view_tickets` | ticket | `ref, iid, state, title, author, assignees, labels, milestone, created_at, updated_at, closed_at, notes, notes_stale` |
| `view_mrs` | merge request | the same plus `reviewers, source_branch, target_branch, draft, merge_status, sha, merged_at` |
| `view_ticket`, `view_mr` | row of one record's thread: header at `seq` 0, then its notes oldest first | `ref, seq, created_at, author, system, text` (rendered Markdown) |
| `view_notes` | note | `ref, kind, iid, position, created_at, author, author_id, system, is_import, type, resolved, len, body` |
| `view_links` | cross-reference GitLab logged as a system note | `ref, kind, iid, created_at, rel, target_kind, target_project, target, target_ref` |
| `view_people` | username | `username, name, user_id` |
| `view_mr_ci_status` | merge request with fetched pipelines: its newest pipeline | `ref, iid, pipeline_id, status, jobs, failed, failed_allowed, unfinished, …` (see `Pipelines.md`) |
| `view_mr_jobs` | CI job of an MR pipeline | `ref, iid, pipeline_id, latest, job_id, name, stage, status, failure_reason, runner, has_log, …` (see `Pipelines.md`) |
| `view_jobs` | any CI job, master and nightly too | the same plus `kind, source, git_ref`; for an MR filter `kind = 'mr' AND iid = …` (see `Pipelines.md`) |
| `view_test_suites` | test job of a pipeline with a test summary | `ref, iid, pipeline_id, latest, git_ref, name, job_id, total, success, failed, skipped, error, …` (see `Pipelines.md`) |

`author` is a username; `assignees`, `reviewers` and `labels` are one
string each. `system` marks GitLab's own notes ("assigned to @x"),
`is_import` the Trac migration's. `notes_stale`: the discussion was never
fetched or is older than the record. `.schema` shows the base tables.

## The four calls

```sql
SELECT ref, state, title, author, labels FROM view_tickets
 WHERE state = 'opened' ORDER BY updated_at DESC LIMIT 20;
-- one record in full; with -noheader the output is a plain transcript
SELECT text FROM view_ticket WHERE ref = '#25166' AND NOT system ORDER BY seq;
-- what people said about a term, with a snippet
SELECT ref, author, substr(body, max(1, instr(lower(body), 'term') - 80), 200)
  FROM view_notes WHERE NOT system AND NOT is_import AND body LIKE '%term%';
-- what a record links to; the reverse direction scans every system note (~2 s)
SELECT rel, target_ref FROM view_links WHERE ref = '#25166';
SELECT ref, rel FROM view_links WHERE target_ref = '#25166';
```

A batch is `WHERE ref IN ('#1', '!2')`, never a shell loop. A thread can
run to hundreds of notes with multi-KB bodies: when `notes` is large, list
`seq, author, length(text)` first, then select the `seq` you want.

## Gotchas

- Search ids as `'%#3772%'`, `'%!7788%'` or `'%/issues/3772%'`; a bare
  number matches digits inside SHAs.
- `LIKE` is a full scan, subsecond warm and ~8 s cold, and case-insensitive
  for ASCII: no `lower()` around it.
- Timestamps are ISO text; leave the trailing `Z` off a bound
  (`>= '2026-08-01T12:00:00'`). A bare date works.
- Nicknames are not usernames: `view_people WHERE name LIKE '%…%'` first.
- Ticket URLs are `https://gitlab.haskell.org/ghc/ghc/-/issues/N`, MRs
  `/-/merge_requests/N`.
- Read text in the default mode or `-json`; `-box` and `-markdown` pad
  every line of a body to the widest column.

`queries.sql` (runs as it stands): search with snippets over descriptions
and notes, two terms near each other, thread index then one note, notes by
one person, all-of-several labels, links with titles both ways, coverage
and freshness, Trac import changes. `reassemble.sql` rebuilds a record as
one JSON object. `Pipelines.md` covers CI status, job failures and fetching job logs.

**"Why did CI fail on !N?"**: read `CiFailure.md` and launch the subagent it
describes — it fetches the pipelines, picks a failed job, reads the end of
its log and returns a summary, keeping the log out of your context.
