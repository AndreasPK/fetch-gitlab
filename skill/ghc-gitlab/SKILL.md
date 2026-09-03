---
name: ghc-gitlab
description: Query the local fetch-gitlab SQLite store for gitlab.haskell.org tickets and MR discussions. Used when asked about ghc issues or merge requests.
---

# Querying a fetch-gitlab store

`fetch-gitlab` dumps `ghc/ghc`'s issues and merge requests, with their
discussions, into SQLite — usually `~/.fetch-gitlab/gitlab.db`. Always open it
read-only: a fetch may be writing, and WAL mode allows readers beside the one
writer but nothing else. Never write to a store you did not create.

```
sqlite3 -readonly ~/.fetch-gitlab/gitlab.db "SELECT count(*) FROM records"
```

## Schema

`records` holds tickets and MRs (`kind` = `'ticket'` or `'mr'`, keyed by
`iid`); `notes` holds discussions, keyed by `(kind, iid, position)`. Users,
labels and milestones are interned in their own tables. Everything else is
JSON in `rest`, with the hot fields (title, state, description, dates,
web_url, body, …) as generated columns — `.schema` shows the exact DDL.

Gotchas:

- **`iid` is not `id`.** `iid` is the number in `#25166`/`!13000` and the
  URL; `id` is GitLab's global id. Key on `(kind, iid)`.
- **Lifted fields are not in `rest`.** `json_extract(rest, '$.author')` is
  always NULL, likewise assignee(s), reviewers, closed_by, merged_by, labels,
  milestone. Join `record_users` / `record_labels` / `milestone_row`.
- **A note's author** joins on three columns, not a note id — and the users
  table's JSON column is `json`, not `rest`:

  ```sql
  SELECT n.created_at, u.username, n.body
    FROM notes n
    LEFT JOIN note_users nu ON nu.kind = n.kind AND nu.iid = n.iid
          AND nu.position = n.position AND nu.field = 'author'
    LEFT JOIN users u ON u.row_id = nu.user_row
   WHERE n.kind = 'ticket' AND n.iid = 25166 AND n.system IS NOT 1
   ORDER BY n.created_at;
  ```

- **Notes are stored newest first.** `ORDER BY created_at` to read a
  conversation; `position` is GitLab's reversed order.
- **Most notes are system notes** ("assigned to @x"). `system IS NOT 1`
  keeps what people said; `user_notes_count` counts only those.
- **Timestamps** are ISO 8601 UTC text with milliseconds and compare
  correctly as text — but leave the trailing `Z` off the bound (`Z` sorts
  after `.`, so `>= '…T12:21:43Z'` silently misses records within that
  second). `date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S`, or a bare
  `'2026-08-01'`.
- **One person, several `users` rows** (interned per JSON shape): match and
  group by `username`. Nicknames are often not usernames — resolve first with
  `SELECT DISTINCT username, name FROM users WHERE name LIKE '%…%' OR
  username LIKE '%…%'`.
- **`discussion_updated_at IS NULL` means the notes were never fetched**, not
  that nobody replied. `discussion_updated_at IS NOT updated_at` means they
  are stale.

Text search is `LIKE` over title/description/body — case-insensitive for
ASCII, no FTS, a full scan is subsecond. Common words ("layout", "tag") match
unrelated tickets, so skim candidates' descriptions before trusting a hit;
for proximity or windowed matching, pipe `sqlite3 -json` into grep or python.

`queries.sql` (runs as it stands) keeps the recipes not worth rederiving:
a record reassembled into one JSON object with its discussion, all-of-several
labels, store coverage and staleness.

`Pipelines.md` covers CI: how to efficiently check an MR's pipeline success
status, job failure reasons, and fetch the precise CI build logs.
