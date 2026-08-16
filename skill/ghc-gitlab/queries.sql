-- Queries against a fetch-gitlab SQLite store. See schema.sql for the tables
-- and SKILL.md for what the store is and how to open it.
--
-- The file runs as it stands:
--
--   sqlite3 -readonly ~/.fetch-gitlab/gitlab.db < queries.sql
--
-- Everything below is a SELECT, and -readonly makes that a guarantee rather
-- than an intention -- a store is usually one a fetch is writing to. The
-- parameters are set here and used by name; change them, or splice literals in
-- and take the queries one at a time.

.param set :kind  'ticket'
.param set :iid   25166
.param set :user  'simonpj'
.param set :label 'T::bug'
.param set :since '2026-08-01'
.param set :text  '%specialis%'


-- ===========================================================================
-- 1. One record
-- ===========================================================================

-- A ticket: #25166. Every column here is generated from the JSON, so this
-- costs nothing that reading the row did not already cost.
SELECT iid, state, title, created_at, updated_at, closed_at, web_url,
       user_notes_count, upvotes, downvotes
  FROM records
 WHERE kind = 'ticket' AND iid = :iid;

-- A merge request: !13000. The same table -- kind is what tells them apart --
-- but the fields worth reading differ, and these live in the JSON rather than
-- in generated columns.
SELECT iid, state, title, created_at, updated_at, web_url,
       json_extract(rest, '$.source_branch') AS source_branch,
       json_extract(rest, '$.target_branch') AS target_branch,
       json_extract(rest, '$.merge_status')  AS merge_status,
       json_extract(rest, '$.draft')         AS draft,
       json_extract(rest, '$.merged_at')     AS merged_at,
       json_extract(rest, '$.sha')           AS sha
  FROM records
 WHERE kind = 'mr' AND iid = 13000;

-- Does the store have it at all, and does it have the discussion? A record
-- with has_discussion = 0 has never had its notes fetched: that is a gap in
-- the store, not a record nobody replied to.
SELECT kind, iid, has_discussion, discussion_updated_at, updated_at,
       CASE
         WHEN has_discussion = 0 THEN 'notes never fetched'
         WHEN discussion_updated_at IS updated_at THEN 'notes current'
         ELSE 'notes stale, record changed since'
       END AS discussion
  FROM records
 WHERE kind = :kind AND iid = :iid;


-- ===========================================================================
-- 2. What hangs off a record
-- ===========================================================================
-- author, assignee, closed_by, merged_by, assignees, reviewers, labels and
-- milestone are NOT in `rest`: they are interned in their own tables, so
-- json_extract(rest, '$.author') is always NULL. These are how to get them.

-- Its people, whatever role they held. 'assignees' and 'reviewers' are ordered
-- lists and can have several rows; the rest sit at position 0.
SELECT ru.field, ru.position, u.username, u.name, u.user_id
  FROM record_users ru
  JOIN users u ON u.row_id = ru.user_row
 WHERE ru.kind = :kind AND ru.iid = :iid
 ORDER BY ru.field, ru.position;

-- Its labels, in the order GitLab listed them.
SELECT l.name
  FROM record_labels rl
  JOIN labels l ON l.label_id = rl.label_id
 WHERE rl.kind = :kind AND rl.iid = :iid
 ORDER BY rl.position;

-- Its milestone, if it has one.
SELECT m.title, m.milestone_id,
       json_extract(m.json, '$.state')    AS state,
       json_extract(m.json, '$.due_date') AS due_date,
       json_extract(m.json, '$.web_url')  AS web_url
  FROM records r
  JOIN milestones m ON m.row_id = r.milestone_row
 WHERE r.kind = :kind AND r.iid = :iid;

-- Its discussion, oldest first, with each note's author.
--
-- LEFT JOIN because a note need not have an author row -- nothing in the
-- schema promises one -- and an inner join would silently drop such a note.
-- system = 1 is GitLab talking to itself ("assigned to @x"); drop those with
-- AND n.system IS NOT 1 to read what people actually said.
SELECT n.position, n.created_at, u.username, n.system, n.note_id, n.body
  FROM notes n
  LEFT JOIN note_users nu
         ON nu.kind = n.kind AND nu.iid = n.iid
        AND nu.position = n.position AND nu.field = 'author'
  LEFT JOIN users u ON u.row_id = nu.user_row
 WHERE n.kind = :kind AND n.iid = :iid
 ORDER BY n.created_at;

-- Everything about one record in a single row, for reading rather than
-- joining: the discussion as a count and a list of speakers.
SELECT r.iid, r.state, r.title,
       (SELECT u.username FROM record_users ru JOIN users u ON u.row_id = ru.user_row
         WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'author') AS author,
       (SELECT group_concat(l.name, ', ') FROM record_labels rl JOIN labels l ON l.label_id = rl.label_id
         WHERE rl.kind = r.kind AND rl.iid = r.iid) AS labels,
       (SELECT m.title FROM milestones m WHERE m.row_id = r.milestone_row) AS milestone,
       (SELECT count(*) FROM notes n WHERE n.kind = r.kind AND n.iid = r.iid) AS notes,
       (SELECT count(*) FROM notes n WHERE n.kind = r.kind AND n.iid = r.iid AND n.system IS NOT 1) AS human_notes,
       r.web_url
  FROM records r
 WHERE r.kind = :kind AND r.iid = :iid;


-- ===========================================================================
-- 3. A record put back together as one JSON object
-- ===========================================================================
-- json_patch merges the lifted tables back into `rest`. A patch value of NULL
-- deletes its key, which is what makes an absent milestone or closed_by come
-- out absent rather than null; the HAVING count(*) > 0 on the list fields is
-- the same trick, since an empty aggregate would otherwise insert [].
--
-- This is for reading and for feeding other tools. It is not byte-exact
-- against what GitLab sent: use `show-gl-ghc show '#25166'` to look at a
-- record, or `fetch-gitlab --convert` to move a whole store, both of which go
-- through the code that guarantees the round trip.
--
-- ORDER BY inside an aggregate needs SQLite 3.44 or newer.

-- A ticket, with everything except its notes.
SELECT json_patch(
         r.rest,
         json_object(
           'author',    (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'author'),
           'assignee',  (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'assignee'),
           'closed_by', (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'closed_by'),
           'assignees', (SELECT json_group_array(json(u.json) ORDER BY ru.position)
                           FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'assignees'
                         HAVING count(*) > 0),
           'labels',    (SELECT json_group_array(l.name ORDER BY rl.position)
                           FROM record_labels rl JOIN labels l ON l.label_id = rl.label_id
                          WHERE rl.kind = r.kind AND rl.iid = r.iid
                         HAVING count(*) > 0),
           'milestone', (SELECT json(m.json) FROM milestones m WHERE m.row_id = r.milestone_row)
         )) AS ticket
  FROM records r
 WHERE r.kind = 'ticket' AND r.iid = :iid;

-- A merge request, with its notes as a `discussion` array, oldest first. The
-- shape of one line of the JSON lines store, in other words.
SELECT json_patch(
         r.rest,
         json_object(
           'author',    (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'author'),
           'assignee',  (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'assignee'),
           'closed_by', (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'closed_by'),
           'merged_by', (SELECT json(u.json) FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'merged_by'),
           'assignees', (SELECT json_group_array(json(u.json) ORDER BY ru.position)
                           FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'assignees'
                         HAVING count(*) > 0),
           'reviewers', (SELECT json_group_array(json(u.json) ORDER BY ru.position)
                           FROM record_users ru JOIN users u ON u.row_id = ru.user_row
                          WHERE ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'reviewers'
                         HAVING count(*) > 0),
           'labels',    (SELECT json_group_array(l.name ORDER BY rl.position)
                           FROM record_labels rl JOIN labels l ON l.label_id = rl.label_id
                          WHERE rl.kind = r.kind AND rl.iid = r.iid
                         HAVING count(*) > 0),
           'milestone', (SELECT json(m.json) FROM milestones m WHERE m.row_id = r.milestone_row),
           'discussion',(SELECT json_group_array(
                                  json_patch(n.rest, json_object(
                                    'author',      (SELECT json(u.json) FROM note_users nu JOIN users u ON u.row_id = nu.user_row
                                                     WHERE nu.kind = n.kind AND nu.iid = n.iid
                                                       AND nu.position = n.position AND nu.field = 'author'),
                                    'resolved_by', (SELECT json(u.json) FROM note_users nu JOIN users u ON u.row_id = nu.user_row
                                                     WHERE nu.kind = n.kind AND nu.iid = n.iid
                                                       AND nu.position = n.position AND nu.field = 'resolved_by')))
                                  ORDER BY n.created_at)
                           FROM notes n WHERE n.kind = r.kind AND n.iid = r.iid
                          HAVING count(*) > 0)
         )) AS mr
  FROM records r
 WHERE r.kind = 'mr' AND r.iid = 13000;


-- ===========================================================================
-- 4. Filters
-- ===========================================================================

-- --- By time ---------------------------------------------------------------
--
-- Timestamps are the ISO 8601 text GitLab sent, UTC, to milliseconds:
-- '2026-08-16T17:36:13.075Z'. That sorts and compares correctly as text, so
-- ordinary >= and < are all that is needed, and (kind, updated_at) is indexed.
--
-- Bounds come from date(1), and should be written WITHOUT the trailing Z:
--
--   SINCE=$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%S)
--   sqlite3 -readonly gitlab.db "SELECT ... WHERE updated_at >= '$SINCE'"
--
-- '...T12:21:43.31Z' >= '...T12:21:43' is true, because the stored value is
-- the longer string with the same prefix. With a Z on the bound it is false --
-- 'Z' sorts after '.' -- and a record modified in that second is silently
-- missed. Leaving the Z off keeps the comparison a prefix comparison.
-- A date alone ('2026-08-01') works for the same reason.

-- Changed since :since, most recent first.
SELECT kind, iid, updated_at, state, title
  FROM records
 WHERE kind = :kind AND updated_at >= :since
 ORDER BY updated_at DESC
 LIMIT 20;

-- Created within a window. Half-open, so a month is one clean pair of bounds.
SELECT iid, created_at, state, title
  FROM records
 WHERE kind = 'mr' AND created_at >= '2024-01-01' AND created_at < '2024-02-01'
 ORDER BY created_at
 LIMIT 20;

-- Closed in a window. closed_at is absent from records that were never
-- closed, so it is NULL for them and they drop out on their own.
SELECT iid, closed_at, title
  FROM records
 WHERE kind = 'ticket' AND closed_at >= '2026-01-01'
 ORDER BY closed_at DESC
 LIMIT 20;

-- Open a long time and still moving: old, not closed, touched recently.
SELECT iid, created_at, updated_at, title
  FROM records
 WHERE kind = 'ticket' AND state = 'opened'
   AND created_at < '2020-01-01' AND updated_at >= '2026-01-01'
 ORDER BY updated_at DESC
 LIMIT 20;

-- --- By state --------------------------------------------------------------
-- Tickets are 'opened' or 'closed'; merge requests add 'merged' and 'locked'.
SELECT state, count(*) FROM records WHERE kind = :kind GROUP BY state;

SELECT iid, updated_at, title
  FROM records
 WHERE kind = 'mr' AND state = 'opened'
 ORDER BY updated_at DESC
 LIMIT 20;

-- --- By label --------------------------------------------------------------

-- Carrying one label.
SELECT r.iid, r.state, r.updated_at, r.title
  FROM records r
  JOIN record_labels rl ON rl.kind = r.kind AND rl.iid = r.iid
  JOIN labels l ON l.label_id = rl.label_id
 WHERE r.kind = :kind AND l.name = :label
 ORDER BY r.updated_at DESC
 LIMIT 20;

-- Carrying ALL of several. The count in the HAVING has to match the list.
SELECT r.iid, r.state, r.title
  FROM records r
  JOIN record_labels rl ON rl.kind = r.kind AND rl.iid = r.iid
  JOIN labels l ON l.label_id = rl.label_id
 WHERE r.kind = 'ticket' AND l.name IN ('T::bug', 'P::normal')
 GROUP BY r.kind, r.iid
HAVING count(DISTINCT l.name) = 2
 ORDER BY r.updated_at DESC
 LIMIT 20;

-- Carrying ANY of several: the same without the HAVING, but DISTINCT, since a
-- record matching two of them would otherwise come back twice.
SELECT DISTINCT r.iid, r.title
  FROM records r
  JOIN record_labels rl ON rl.kind = r.kind AND rl.iid = r.iid
  JOIN labels l ON l.label_id = rl.label_id
 WHERE r.kind = 'ticket' AND l.name IN ('T::bug', 'T::feature request')
 LIMIT 20;

-- Carrying none of them.
SELECT r.iid, r.title
  FROM records r
 WHERE r.kind = 'ticket' AND r.state = 'opened'
   AND NOT EXISTS (SELECT 1 FROM record_labels rl JOIN labels l ON l.label_id = rl.label_id
                    WHERE rl.kind = r.kind AND rl.iid = r.iid AND l.name = :label)
 LIMIT 20;

-- What labels are in use, and how much.
SELECT l.name, count(*) AS records
  FROM record_labels rl JOIN labels l ON l.label_id = rl.label_id
 WHERE rl.kind = :kind
 GROUP BY l.name
 ORDER BY records DESC
 LIMIT 20;

-- --- By person -------------------------------------------------------------
-- Match on username, which is stable; name is a display name and repeats.

-- Wrote it.
SELECT r.iid, r.state, r.created_at, r.title
  FROM records r
  JOIN record_users ru ON ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'author'
  JOIN users u ON u.row_id = ru.user_row
 WHERE r.kind = :kind AND u.username = :user
 ORDER BY r.created_at DESC
 LIMIT 20;

-- Assigned to them, in either of the two fields GitLab uses for it.
SELECT DISTINCT r.iid, r.state, r.title
  FROM records r
  JOIN record_users ru ON ru.kind = r.kind AND ru.iid = r.iid
  JOIN users u ON u.row_id = ru.user_row
 WHERE r.kind = :kind AND ru.field IN ('assignee', 'assignees') AND u.username = :user
 ORDER BY r.updated_at DESC
 LIMIT 20;

-- Involved at all, and how: author, assignee, reviewer, closer, merger.
SELECT r.kind, r.iid, group_concat(DISTINCT ru.field) AS roles, r.title
  FROM records r
  JOIN record_users ru ON ru.kind = r.kind AND ru.iid = r.iid
  JOIN users u ON u.row_id = ru.user_row
 WHERE u.username = :user
 GROUP BY r.kind, r.iid
 ORDER BY r.updated_at DESC
 LIMIT 20;

-- Said something on it. Note the three-column join into note_users: a note is
-- identified by (kind, iid, position), not by its id.
SELECT DISTINCT n.kind, n.iid
  FROM notes n
  JOIN note_users nu ON nu.kind = n.kind AND nu.iid = n.iid
                    AND nu.position = n.position AND nu.field = 'author'
  JOIN users u ON u.row_id = nu.user_row
 WHERE u.username = :user AND n.system IS NOT 1
 LIMIT 20;

-- Who is in the store at all. The same person can hold several rows: users are
-- interned by exact JSON, and a note's author carries fewer fields than a
-- ticket's, so group by username rather than counting rows.
SELECT username, name, count(*) AS shapes, min(user_id) AS user_id
  FROM users
 GROUP BY username
 ORDER BY username
 LIMIT 20;

-- --- By milestone ----------------------------------------------------------
SELECT r.iid, r.state, r.title
  FROM records r
  JOIN milestones m ON m.row_id = r.milestone_row
 WHERE r.kind = 'mr' AND m.title = '9.10.1'
 LIMIT 20;

SELECT m.title, count(*) AS records
  FROM records r JOIN milestones m ON m.row_id = r.milestone_row
 GROUP BY m.title
 ORDER BY records DESC
 LIMIT 20;

-- --- By text ---------------------------------------------------------------
-- LIKE is a scan: a few hundred milliseconds over the whole store, which is
-- fine interactively. There is no full text index. LIKE is case insensitive
-- for ASCII; use GLOB for case sensitive matching.

-- In the title.
SELECT iid, state, updated_at, title
  FROM records
 WHERE kind = :kind AND title LIKE :text
 ORDER BY updated_at DESC
 LIMIT 20;

-- In the title or the description.
SELECT iid, state, title
  FROM records
 WHERE kind = :kind AND (title LIKE :text OR description LIKE :text)
 LIMIT 20;

-- In what people said, with the record and speaker.
SELECT n.kind, n.iid, u.username, n.created_at,
       substr(replace(n.body, char(10), ' '), 1, 80) AS said
  FROM notes n
  JOIN note_users nu ON nu.kind = n.kind AND nu.iid = n.iid
                    AND nu.position = n.position AND nu.field = 'author'
  JOIN users u ON u.row_id = nu.user_row
 WHERE n.system IS NOT 1 AND n.body LIKE '%simplifier tick%'
 ORDER BY n.created_at DESC
 LIMIT 20;

-- --- Combining -------------------------------------------------------------
-- The filters compose the way they read: open tickets labelled :label that
-- :user has touched since :since.
SELECT DISTINCT r.iid, r.updated_at, r.title
  FROM records r
  JOIN record_labels rl ON rl.kind = r.kind AND rl.iid = r.iid
  JOIN labels l ON l.label_id = rl.label_id
  JOIN record_users ru ON ru.kind = r.kind AND ru.iid = r.iid
  JOIN users u ON u.row_id = ru.user_row
 WHERE r.kind = 'ticket'
   AND r.state = 'opened'
   AND l.name = :label
   AND u.username = :user
   AND r.updated_at >= '2025-01-01'
 ORDER BY r.updated_at DESC
 LIMIT 20;


-- ===========================================================================
-- 5. The store itself
-- ===========================================================================

-- What it holds, and how much of the discussion has been fetched. A cold run
-- fetches records first and discussions second, so a store part way through
-- shows records with has_discussion = 0.
SELECT kind,
       count(*)                 AS records,
       sum(has_discussion)      AS with_notes,
       sum(has_discussion = 0)  AS without_notes,
       min(created_at)          AS oldest,
       max(updated_at)          AS newest
  FROM records
 GROUP BY kind;

-- How far back it goes and how current it is -- max(updated_at) is where the
-- next incremental run will start from.
SELECT max(updated_at) AS watermark FROM records;

-- Row counts, which is where the sharing shows: users and labels are a
-- rounding error against notes.
SELECT 'records' AS t, count(*) AS n FROM records
UNION ALL SELECT 'notes',      count(*) FROM notes
UNION ALL SELECT 'note_users', count(*) FROM note_users
UNION ALL SELECT 'users',      count(*) FROM users
UNION ALL SELECT 'labels',     count(*) FROM labels
UNION ALL SELECT 'milestones', count(*) FROM milestones;

-- Which records a run still owes notes for.
SELECT kind, iid, updated_at, title
  FROM records
 WHERE has_discussion = 0
 ORDER BY updated_at DESC
 LIMIT 20;

-- Which have notes that have gone stale: the record changed after its
-- discussion was fetched, so the next run will fetch it again.
SELECT kind, iid, discussion_updated_at, updated_at
  FROM records
 WHERE has_discussion = 1 AND discussion_updated_at IS NOT updated_at
 LIMIT 20;

-- The schema version the store was written with. fetch-gitlab refuses a store
-- whose version it does not know.
SELECT key, value FROM meta;


-- ===========================================================================
-- 6. Aggregates worth having
-- ===========================================================================

-- The busiest discussions.
SELECT n.kind, n.iid, count(*) AS notes, r.title
  FROM notes n JOIN records r ON r.kind = n.kind AND r.iid = n.iid
 GROUP BY n.kind, n.iid
 ORDER BY notes DESC
 LIMIT 10;

-- Who talks most, system notes excluded.
SELECT u.username, count(*) AS notes
  FROM note_users nu
  JOIN users u ON u.row_id = nu.user_row
  JOIN notes n ON n.kind = nu.kind AND n.iid = nu.iid AND n.position = nu.position
 WHERE nu.field = 'author' AND n.system IS NOT 1
 GROUP BY u.username
 ORDER BY notes DESC
 LIMIT 10;

-- Activity by month, over records and over notes.
SELECT substr(created_at, 1, 7) AS month, count(*) AS opened
  FROM records
 WHERE kind = :kind AND created_at >= '2025-01'
 GROUP BY month
 ORDER BY month;

SELECT substr(created_at, 1, 7) AS month, count(*) AS notes
  FROM notes
 WHERE created_at >= '2025-01' AND system IS NOT 1
 GROUP BY month
 ORDER BY month;
