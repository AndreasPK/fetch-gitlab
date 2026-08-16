---
name: ghc-gitlab
description: Query a fetch-gitlab SQLite store of GHC's GitLab tickets and merge requests - schema, single-record lookups, discussions, and filters by date, label, user, state, milestone or text. Use when asked about ghc/ghc issues (#123), merge requests (!123), or what people said on them.
---

# Querying a fetch-gitlab store

`fetch-gitlab` dumps `ghc/ghc`'s issues and merge requests, with their
discussions, into a SQLite database. This skill is how to read one.

- `schema.sql` — the tables, exactly as the tool creates them, with commentary.
- `queries.sql` — worked queries. Runs as it stands against a store.

For a single record, the project also ships a reader that needs no SQL:

```
show-gl-ghc show '#25166' --full
```

## Opening one

The store is usually at `~/.fetch-gitlab/gitlab.db`. Open it read-only:

```
sqlite3 -readonly ~/.fetch-gitlab/gitlab.db "SELECT count(*) FROM records"
sqlite3 -readonly -box ~/.fetch-gitlab/gitlab.db < queries.sql
```

`-readonly` matters. A fetch may be running, and it is the only thing that
should ever write here — the store is in WAL mode, so reading alongside a
writer is fine, but a second writer is not. Never `VACUUM`, `ALTER` or write to
a store you did not create; `fetch-gitlab --convert` is how a store is copied.

If a store is somewhere else, the directory may also hold `.bak-` copies of it
and a `gitlab.db-wal` beside the live one. The `-wal` is part of the database,
not a leftover: a run checkpoints into it and folds it back only when it
closes, so `gitlab.db` alone can be hours behind what a query returns.

## The model in six lines

`records` holds both kinds, told apart by `kind` = `'ticket'` or `'mr'` and
keyed by `iid`. `notes` holds the discussions, one row per note, belonging to a
record by `(kind, iid)`. `users`, `labels` and `milestones` are interned and
pointed at from `record_users`, `record_labels`, `records.milestone_row` and
`note_users`. Everything else about a record or a note is the JSON in `rest`,
with the columns worth querying — title, state, dates, body — generated from
it, so they can be selected and indexed like ordinary columns.

## What will trip you up

**`iid` is not `id`.** `iid` is the project local number, the one in `#25166`
and in the URL. `id` is GitLab's global id. Queries key on `(kind, iid)`.

**The lifted fields are not in `rest`.** `json_extract(rest, '$.author')` is
always NULL, and so are `assignee`, `assignees`, `reviewers`, `closed_by`,
`merged_by`, `labels` and `milestone`. They live in the interned tables; join
`record_users` on `(kind, iid, field)` or `record_labels`. Section 2 of
`queries.sql` covers each, and section 3 puts a whole record back together as
one JSON object.

**Notes are stored newest first.** `position` is GitLab's order, so
`ORDER BY position` reads backwards. `ORDER BY created_at` for a conversation;
`show-gl-ghc --full` already does that.

**Most notes are not comments.** `system = 1` marks GitLab talking to itself
("assigned to @x", "mentioned in merge request !123"), and they outnumber real
comments. `AND system IS NOT 1` to exclude them. The record's
`user_notes_count` counts only the human ones, so it will not match
`count(*)` over `notes`.

**Timestamps are text, and compare correctly as text** — ISO 8601, UTC, to
milliseconds: `2026-08-16T17:36:13.075Z`. Generate bounds with `date`, and
leave the trailing `Z` off:

```
SINCE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S)
sqlite3 -readonly ~/.fetch-gitlab/gitlab.db \
  "SELECT iid, updated_at, title FROM records
    WHERE kind = 'ticket' AND updated_at >= '$SINCE' ORDER BY updated_at DESC"
```

With the `Z` on the bound the comparison stops being a prefix comparison —
`'…T12:21:43.31Z' >= '…T12:21:43Z'` is false, because `Z` sorts after `.` —
and records modified within that second are silently missed. A bare date,
`'2026-08-01'`, is fine for the same reason.

**A person can hold several `users` rows.** Users are interned by their exact
JSON, and a note's author carries fewer fields than a ticket's; identical
objects are shared, differing ones are kept apart. Match on `username`, and
group by it rather than counting rows.

**An absent discussion is not an empty one.** `has_discussion = 0` means the
notes have never been fetched — a gap in the store, not a record nobody
replied to. A cold run fetches every record first and the discussions second,
so a store part way through has plenty of them. `discussion_updated_at` is the
record's `updated_at` when its notes were fetched; where it differs from
`updated_at` now, the discussion is stale and the next run will refetch it.

**The JSON is what `gitlab-haskell` parsed, re-encoded.** Fields the library
does not model are not in the store, and fields it holds as `Nothing` are
absent rather than null. Tickets carry `description`, `state`, `web_url`,
`closed_at`, `weight`, `time_stats`, `references`, `_links`; merge requests
carry `source_branch`, `target_branch`, `merge_status`, `draft`, `sha`,
`merged_at`. `SELECT DISTINCT key FROM records, json_each(rest)` says what is
actually there in a given store.

## Query index

`queries.sql`, in order:

1. One record — a ticket, a merge request, and whether its discussion is there.
2. What hangs off it — people by role, labels, milestone, notes with authors,
   and a one-row summary.
3. A record rebuilt as a single JSON object, with and without its discussion.
4. Filters — updated/created/closed windows, state, labels (any, all, none),
   people by role, people who commented, milestone, text in titles,
   descriptions and note bodies, and how they compose.
5. The store itself — coverage, watermark, row counts, what a run still owes.
6. Aggregates — busiest discussions, who talks most, activity by month.
