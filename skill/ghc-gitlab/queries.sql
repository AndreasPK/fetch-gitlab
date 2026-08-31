-- Nontrivial queries against a fetch-gitlab SQLite store. SKILL.md has the
-- schema and its gotchas; `.schema` on a store has the exact DDL. The file
-- runs as it stands:
--
--   sqlite3 -readonly ~/.fetch-gitlab/gitlab.db < queries.sql
--
-- Plain filters (by date, state, label, person, LIKE over text) are not
-- here: write those directly against the generated columns and the
-- record_users / record_labels joins.


-- A record rebuilt as one JSON object with its discussion, oldest first.
-- json_patch merges the lifted tables back into `rest`. A patch value of
-- NULL deletes its key, which is what makes an absent milestone come out
-- absent rather than null; HAVING count(*) > 0 does the same for the list
-- fields, since an empty aggregate would otherwise insert []. On a ticket
-- the merged_by/reviewers subqueries are empty and simply drop out.
--
-- Not byte-exact against what GitLab sent: `fetch-gitlab --convert` goes
-- through the code that guarantees the round trip. ORDER BY inside an
-- aggregate needs SQLite 3.44 or newer.
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
         )) AS record
  FROM records r
 WHERE r.kind = 'mr' AND r.iid = 13000;


-- Carrying ALL of several labels: the HAVING count must match the list.
-- (ANY of several is the same without the HAVING, plus DISTINCT.)
SELECT r.iid, r.state, r.title
  FROM records r
  JOIN record_labels rl ON rl.kind = r.kind AND rl.iid = r.iid
  JOIN labels l ON l.label_id = rl.label_id
 WHERE r.kind = 'ticket' AND l.name IN ('T::bug', 'P::normal')
 GROUP BY r.kind, r.iid
HAVING count(DISTINCT l.name) = 2
 ORDER BY r.updated_at DESC
 LIMIT 20;


-- Store coverage: what it holds, how much of the discussion has been
-- fetched, and the watermark an incremental run resumes from. A cold run
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

-- Which records a run still owes notes for, and which have notes gone stale
-- (the record changed after its discussion was fetched).
SELECT kind, iid, updated_at, title
  FROM records
 WHERE has_discussion = 0
 ORDER BY updated_at DESC
 LIMIT 20;

SELECT kind, iid, discussion_updated_at, updated_at
  FROM records
 WHERE has_discussion = 1 AND discussion_updated_at IS NOT updated_at
 LIMIT 20;
