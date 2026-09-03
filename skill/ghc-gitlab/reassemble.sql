-- A record rebuilt as one JSON object with its discussion, oldest first —
-- for extracting a record to JSONL. Runs as it stands:
--
--   sqlite3 -readonly ~/.fetch-gitlab/gitlab.db < reassemble.sql
--
-- json_patch merges the lifted tables back into `rest`. A patch value of
-- NULL deletes its key, which is what makes an absent milestone come out
-- absent rather than null; HAVING count(*) > 0 does the same for the list
-- fields, since an empty aggregate would otherwise insert []. On a ticket
-- the merged_by/reviewers subqueries are empty and simply drop out.
--
-- Not byte-exact against what GitLab sent: the store's own reader is what
-- guarantees the round trip. ORDER BY inside an aggregate needs SQLite 3.44
-- or newer.
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
 WHERE r.ref = '!13000';
