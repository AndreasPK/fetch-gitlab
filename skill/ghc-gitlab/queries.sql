-- Recipes against a fetch-gitlab SQLite store, schema patch 4 or later
-- (the view_* views). SKILL.md has the views and gotchas; `.schema` on a
-- store has the exact DDL. The file runs as it stands:
--
--   sqlite3 -readonly ~/.fetch-gitlab/gitlab.db < queries.sql
--
-- Plain filters (by date, state, label, person, ref) are not here: write
-- those against the views directly.


-- Search with snippets over descriptions and human notes, one row per
-- hit, with the record's title. `t` takes several terms. The LIKE on the
-- raw `rest` column skips the JSON parse for rows that cannot match and
-- halves the scan, which is why this reads the base tables.
WITH t(term) AS (VALUES ('interestingDict')),
hit AS (
  SELECT r.ref, 0 AS position, t.term,
         r.title || char(10) || coalesce(r.description, '') AS txt
    FROM records r JOIN t
   WHERE r.rest LIKE '%' || t.term || '%'
     AND (r.title LIKE '%' || t.term || '%' OR r.description LIKE '%' || t.term || '%')
  UNION ALL
  SELECT n.ref, n.position, t.term, n.body
    FROM notes n JOIN t
   WHERE n.rest LIKE '%' || t.term || '%' AND n.body LIKE '%' || t.term || '%'
     AND n.system IS NOT 1 AND n.body NOT LIKE '<!-- {"blocked_by"%')
SELECT h.ref, h.position, r.state, substr(r.title, 1, 50) AS title, h.term,
       replace(substr(h.txt, max(1, instr(lower(h.txt), lower(h.term)) - 60), 140),
               char(10), ' ') AS snippet
  FROM hit h JOIN records r ON r.ref = h.ref
 ORDER BY h.ref, h.position
 LIMIT 40;


-- Two terms near each other: the second within 300 characters of the
-- first occurrence of the first. Replaces grep -P over flattened rows.
SELECT ref, position, author,
       replace(substr(body, max(1, instr(lower(body), 'noinline') - 150), 300), char(10), ' ') AS around
  FROM view_notes
 WHERE NOT system AND NOT is_import AND body LIKE '%noinline%'
   AND substr(body, max(1, instr(lower(body), 'noinline') - 300), 600) LIKE '%speciali%'
 LIMIT 20;


-- Thread index: who said what, when, how much. Read this before printing
-- bodies, then fetch the ones you want by seq.
SELECT seq, author, substr(created_at, 1, 10) AS at, length(text) AS len,
       substr(replace(text, char(10), ' '), 1, 80) AS head
  FROM view_ticket
 WHERE ref = '#27750' AND NOT system
 ORDER BY seq;

SELECT text FROM view_ticket WHERE ref = '#27750' AND seq = 1;


-- What one person said about something. view_people resolves a name to
-- the username first.
SELECT ref, position, substr(created_at, 1, 10) AS at,
       substr(replace(body, char(10), ' '), 1, 100) AS head
  FROM view_notes
 WHERE author = 'AndreasK' AND NOT system AND body LIKE '%interestingDict%'
 ORDER BY created_at DESC
 LIMIT 20;


-- Carrying ALL of several labels: the HAVING count must match the list.
-- (ANY of several is `labels LIKE '%x%' OR labels LIKE '%y%'` on the view.)
SELECT r.ref, r.state, r.title
  FROM records r
  JOIN record_labels rl ON rl.kind = r.kind AND rl.iid = r.iid
  JOIN labels l ON l.label_id = rl.label_id
 WHERE r.kind = 'ticket' AND l.name IN ('T::bug', 'P::normal')
 GROUP BY r.kind, r.iid
HAVING count(DISTINCT l.name) = 2
 ORDER BY r.updated_at DESC
 LIMIT 20;


-- Links with titles, both directions. `rel` is one of mentioned_in,
-- closed_via, related_to, duplicate_of, duplicated_by; target_ref is NULL
-- for commits and other projects (target_project says which). Mentions in
-- prose that GitLab did not log are a `body LIKE '%#23109%'` on view_notes.
SELECT l.rel, l.target_kind, coalesce(l.target_ref, l.target) AS target, r.state, r.title
  FROM view_links l LEFT JOIN records r ON r.ref = l.target_ref
 WHERE l.ref = '#23109'
 ORDER BY l.created_at;

SELECT l.ref, l.rel, substr(l.created_at, 1, 10) AS at, r.state, r.title
  FROM view_links l JOIN records r ON r.ref = l.ref
 WHERE l.target_ref = '#23109'
 ORDER BY l.created_at;


-- Coverage and freshness: what the store holds, how much of the discussion
-- has been fetched, and the watermark an incremental run resumes from. A
-- cold run fetches records first and discussions second, so a store part
-- way through shows records with a NULL discussion_updated_at.
SELECT kind,
       count(*)                                AS records,
       sum(discussion_updated_at IS NOT NULL)  AS with_notes,
       sum(discussion_updated_at IS NULL)      AS without_notes,
       sum(discussion_updated_at IS NOT NULL
           AND discussion_updated_at IS NOT updated_at) AS stale_notes,
       min(created_at)                         AS oldest,
       max(updated_at)                         AS newest
  FROM records
 GROUP BY kind;


-- Trac import changes unpacked: the migration wrote each field change of
-- an old ticket as a note whose body is an HTML comment holding JSON.
SELECT n.ref, n.position, substr(n.created_at, 1, 10) AS at, j.key AS field,
       substr(json_extract(j.value, '$.old'), 1, 60) AS old,
       substr(json_extract(j.value, '$.new'), 1, 60) AS new
  FROM view_notes n, json_each(substr(n.body, 6, length(n.body) - 9)) j
 WHERE n.ref = '#12996' AND n.is_import
 ORDER BY n.position DESC, j.key
 LIMIT 40;
