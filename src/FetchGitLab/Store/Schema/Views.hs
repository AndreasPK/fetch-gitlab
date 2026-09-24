{-# LANGUAGE OverloadedStrings #-}

{- | Views over the store for the agent, or person, holding a @sqlite3@
prompt. Schema patch 4.

The base tables are shaped for a faithful, compact dump: a record's author
is a row in @record_users@ pointing at an interned @users@ row, a note's
author takes a three-column join, the labels are a junction table, and the
Trac-import notes look like any other note until one reads the body. A
week of session logs showed every consumer rewriting the same joins, the
same @system IS NOT 1@, the same snippet extraction, and rendering a
thread by hand in Python. These views are those queries, written once.

Two shapes are on offer for a record. The plural views (@view_tickets@,
@view_mrs@, @view_notes@) are one row per thing with plain columns, for
lists and searches. The singular views (@view_ticket@, @view_mr@) are one
record as a thread: a header row followed by its notes, oldest first, each
row's @text@ already rendered as a Markdown chunk. Their purpose is
reading, and rendering in SQL is what makes @sqlite3@'s default output a
transcript rather than pipe-separated rows in which a note body's newlines
are indistinguishable from row breaks. The rendered column is named @text@
and not @body@ so that it cannot be taken for the raw note; the raw body is
in @view_notes@.

Nothing here is indexed on its own: every view stands on @records@,
@notes@ and the @ref@ index from patch 3, and the kind filters are written
plainly (@kind = 'ticket'@) because patch 3 also gave the store planner
statistics. Without those SQLite prefers the @kind@ prefix of a primary
key over any other index, whatever the query.

A view is frozen in the store that holds it: changing one is a later patch
of @DROP VIEW IF EXISTS@ and @CREATE VIEW@, and a column a view mentions
cannot be dropped until the view is. Views are not part of the base schema
because SQLite resolves a view's columns when it is created, and the base
statements run before the patches that add the columns.
-}
module FetchGitLab.Store.Schema.Views (
    viewStatements,
    ciViewStatements,
    jobAndTestViewStatements,
) where

import Data.Text (Text)
import qualified Data.Text as T

{- | The views, in an order that can be executed as given. Each is
@CREATE VIEW IF NOT EXISTS@, so the patch is repeatable.
-}
viewStatements :: [Text]
viewStatements =
    [ viewTickets
    , viewMrs
    , threadView "view_ticket" "ticket" []
    , threadView "view_mr" "mr" mrHeaderLines
    , viewNotes
    , viewLinks
    , viewPeople
    ]

{- | People and labels of a record, as the list views show them: usernames
space-separated, labels comma-separated, in the record's own order.
-}
userList :: Text -> Text
userList field =
    "(SELECT group_concat(username, ' ') FROM \
    \   (SELECT u2.username FROM record_users ru2 JOIN users u2 ON u2.row_id = ru2.user_row \
    \     WHERE ru2.kind = r.kind AND ru2.iid = r.iid AND ru2.field = '"
        <> field
        <> "' \
           \     ORDER BY ru2.position))"

labelList :: Text
labelList =
    "(SELECT group_concat(name, ', ') FROM \
    \   (SELECT l.name FROM record_labels rl JOIN labels l ON l.label_id = rl.label_id \
    \     WHERE rl.kind = r.kind AND rl.iid = r.iid \
    \     ORDER BY rl.position))"

milestoneTitle :: Text
milestoneTitle = "(SELECT title FROM milestones WHERE row_id = r.milestone_row)"

{- | The record joined to its author; the inner join is deliberate, so that
@WHERE author = 'x'@ starts from the @users_username@ index.
-}
recordWithAuthor :: Text -> Text
recordWithAuthor kind =
    "FROM records r \
    \JOIN record_users ru ON ru.kind = r.kind AND ru.iid = r.iid AND ru.field = 'author' \
    \JOIN users u ON u.row_id = ru.user_row \
    \WHERE r.kind = '"
        <> kind
        <> "'"

-- | True when the discussion was never fetched or is older than the record.
notesStale :: Text
notesStale = "(r.discussion_updated_at IS NOT r.updated_at) AS notes_stale"

viewTickets :: Text
viewTickets =
    "CREATE VIEW IF NOT EXISTS view_tickets AS \
    \SELECT r.ref, r.iid, r.state, r.title, \
    \       u.username AS author, "
        <> userList "assignees"
        <> " AS assignees, "
        <> labelList
        <> " AS labels, "
        <> milestoneTitle
        <> " AS milestone, \
           \       r.created_at, r.updated_at, r.closed_at, \
           \       r.user_notes_count AS notes, "
        <> notesStale
        <> " "
        <> recordWithAuthor "ticket"

viewMrs :: Text
viewMrs =
    "CREATE VIEW IF NOT EXISTS view_mrs AS \
    \SELECT r.ref, r.iid, r.state, r.title, \
    \       u.username AS author, "
        <> userList "assignees"
        <> " AS assignees, "
        <> userList "reviewers"
        <> " AS reviewers, "
        <> labelList
        <> " AS labels, "
        <> milestoneTitle
        <> " AS milestone, \
           \       json_extract(r.rest, '$.source_branch') AS source_branch, \
           \       json_extract(r.rest, '$.target_branch') AS target_branch, \
           \       json_extract(r.rest, '$.draft')         AS draft, \
           \       json_extract(r.rest, '$.merge_status')  AS merge_status, \
           \       json_extract(r.rest, '$.sha')           AS sha, \
           \       r.created_at, r.updated_at, \
           \       json_extract(r.rest, '$.merged_at')     AS merged_at, \
           \       r.closed_at, \
           \       r.user_notes_count AS notes, "
        <> notesStale
        <> " "
        <> recordWithAuthor "mr"

{- | An optional line of the thread header: the label and an expression;
the line is omitted when the expression is NULL.
-}
headerLine :: Text -> Text -> Text
headerLine label expr = "coalesce(char(10) || '" <> label <> ": ' || " <> expr <> ", '')"

-- | What every record's header shows after the title and state.
commonHeaderLines :: [Text]
commonHeaderLines =
    [ headerLine "labels" labelList
    , headerLine "milestone" milestoneTitle
    , headerLine "assignees" (userList "assignees")
    ]

-- | What a merge request's header adds.
mrHeaderLines :: [Text]
mrHeaderLines =
    [ headerLine "reviewers" (userList "reviewers")
    , headerLine "branch" "(json_extract(r.rest, '$.source_branch') || ' → ' || json_extract(r.rest, '$.target_branch'))"
    , headerLine "merge_status" "json_extract(r.rest, '$.merge_status')"
    , headerLine "merged" "json_extract(r.rest, '$.merged_at')"
    , "CASE WHEN json_extract(r.rest, '$.draft') THEN char(10) || 'draft: yes' ELSE '' END"
    ]

{- | One record as a thread. Row @seq@ 0 is the record itself; the notes
follow in GitLab's own order (the store keeps position 0 newest, and
GitLab groups diff threads, so @seq@ and @created_at@ do not always agree).

@seq@ is a correlated count rather than a window function: a window makes
SQLite materialise the whole view before applying @WHERE ref = …@, where
the count is one range lookup on the primary key per note and the
@notes_ref@ index still drives the query.
-}
threadView :: Text -> Text -> [Text] -> Text
threadView name kind extraLines =
    "CREATE VIEW IF NOT EXISTS "
        <> name
        <> " AS \
           \SELECT r.ref, 0 AS seq, r.created_at, u.username AS author, 0 AS system, \
           \       '# ' || r.ref || ' ' || r.title || char(10) \
           \       || 'author: ' || u.username || ' · ' || substr(r.created_at, 1, 16) || char(10) \
           \       || 'state: ' || r.state "
        <> T.concat [" || " <> l | l <- commonHeaderLines <> extraLines]
        <> " || char(10) || char(10) || coalesce(r.description, '') || char(10) AS text "
        <> recordWithAuthor kind
        <> " UNION ALL \
           \SELECT ref, seq, created_at, author, system, \
           \       '### ' || seq || ' · ' || author || ' · ' || substr(created_at, 1, 16) \
           \       || CASE WHEN system THEN ' · system' ELSE '' END \
           \       || char(10) || char(10) || body || char(10) AS text \
           \  FROM (SELECT n.ref, \
           \               (SELECT count(*) FROM notes n2 WHERE n2.kind = n.kind AND n2.iid = n.iid) - n.position AS seq, \
           \               n.created_at, u.username AS author, n.system, n.body \
           \          FROM notes n \
           \          JOIN note_users nu ON nu.kind = n.kind AND nu.iid = n.iid \
           \                            AND nu.position = n.position AND nu.field = 'author' \
           \          JOIN users u ON u.row_id = nu.user_row \
           \         WHERE n.kind = '"
        <> kind
        <> "')"

{- | One row per note with its author and the two flags a search wants:
@system@ for GitLab's own notes and @is_import@ for the Trac migration's,
whose body is exactly an HTML comment holding the field changes.
-}
viewNotes :: Text
viewNotes =
    "CREATE VIEW IF NOT EXISTS view_notes AS \
    \SELECT n.ref, n.kind, n.iid, n.position, \
    \       n.created_at, u.username AS author, u.user_id AS author_id, \
    \       n.system, (n.body LIKE '<!-- {\"blocked_by\"%') AS is_import, \
    \       n.type, n.resolved, length(n.body) AS len, n.body \
    \  FROM notes n \
    \  JOIN note_users nu ON nu.kind = n.kind AND nu.iid = n.iid \
    \                    AND nu.position = n.position AND nu.field = 'author' \
    \  JOIN users u ON u.row_id = nu.user_row"

{- | The cross-references GitLab records as system notes, which are the only
record of them the store has. The target is split into what kind of thing
it is, which project it lives in (empty for this one) and its number or
sha; @target_ref@ is the joinable @#N@/@!N@ for same-project targets.
-}
viewLinks :: Text
viewLinks =
    "CREATE VIEW IF NOT EXISTS view_links AS \
    \WITH sys AS ( \
    \  SELECT kind, iid, ref, created_at, \
    \         CASE "
        <> T.concat [" WHEN body LIKE '" <> p <> "%' THEN '" <> rel <> "'" | (p, rel, _) <- prefixes]
        <> " END AS rel, \
           \         CASE "
        <> T.concat [" WHEN body LIKE '" <> p <> "%' THEN " <> tailOf | (p, _, tailOf) <- prefixes]
        <> " END AS tail \
           \    FROM notes WHERE system = 1 \
           \), split AS ( \
           \  SELECT kind, iid, ref, created_at, rel, \
           \         CASE WHEN instr(tail, '#') > 0 THEN 'ticket' \
           \              WHEN instr(tail, '!') > 0 THEN 'mr' \
           \              ELSE 'commit' END AS target_kind, \
           \         CASE WHEN instr(tail, '#') > 0 THEN substr(tail, 1, instr(tail, '#') - 1) \
           \              WHEN instr(tail, '!') > 0 THEN substr(tail, 1, instr(tail, '!') - 1) \
           \              WHEN instr(tail, '@') > 0 THEN substr(tail, 1, instr(tail, '@') - 1) \
           \              ELSE '' END AS target_project, \
           \         CASE WHEN instr(tail, '#') > 0 THEN substr(tail, instr(tail, '#') + 1) \
           \              WHEN instr(tail, '!') > 0 THEN substr(tail, instr(tail, '!') + 1) \
           \              WHEN instr(tail, '@') > 0 THEN substr(tail, instr(tail, '@') + 1) \
           \              ELSE tail END AS target \
           \    FROM sys WHERE rel IS NOT NULL \
           \) \
           \SELECT ref, kind, iid, created_at, rel, target_kind, target_project, target, \
           \       CASE WHEN target_project = '' AND target_kind = 'ticket' THEN '#' || target \
           \            WHEN target_project = '' AND target_kind = 'mr'     THEN '!' || target \
           \       END AS target_ref \
           \  FROM split"
  where
    -- The fixed prefixes GitLab uses, the relation each states, and the
    -- expression that cuts the target out of the body.
    prefixes :: [(Text, Text, Text)]
    prefixes =
        [ cut "mentioned in issue " "mentioned_in"
        , cut "mentioned in merge request " "mentioned_in"
        , cut "mentioned in commit " "mentioned_in"
        , cut "closed via merge request " "closed_via"
        , cut "closed via commit " "closed_via"
        , cut "marked this issue as related to " "related_to"
        , cut "marked this issue as a duplicate of " "duplicate_of"
        , ("marked % as a duplicate of this issue", "duplicated_by", "substr(body, 8, instr(body, ' as a duplicate') - 8)")
        ]
    cut p rel = (p, rel, "substr(body, " <> T.pack (show (T.length p + 1)) <> ")")

{- | One row per person. The @users@ table has one row per JSON shape a
person arrived in; this folds them to the username.
-}
viewPeople :: Text
viewPeople =
    "CREATE VIEW IF NOT EXISTS view_people AS \
    \SELECT username, max(name) AS name, user_id FROM users GROUP BY username"

{- | The views over pipelines and jobs. Part of schema patch 5, after the
statements that create @job_logs@, which @view_jobs@ reads.

These views help answer: What did happen during a pipeline, which jobs failed
and which jobs failed
@view_mr_ci_status@ answers the first half in one row. In @view_jobs@,
@latest@ marks the jobs of that same pipeline, so the second half is
@WHERE iid = ? AND latest AND status = 'failed'@ rather than a correlated
subquery written out again. Filter on @iid@: it reaches the
@pipelines_record@ index, where @ref@ is computed and cannot.
-}
ciViewStatements :: [Text]
ciViewStatements = [viewMrCiStatus, viewJobs]

{- | True for the newest pipeline of its merge request. Pipeline ids are
project-wide and ascending, so the highest is the last one created.
-}
latestPipeline :: Text
latestPipeline =
    "(p.pipeline_id = (SELECT max(p2.pipeline_id) FROM pipelines p2 \
    \                   WHERE p2.kind = p.kind AND p2.iid = p.iid)) AS latest"

{- | One row per merge request (for those having stored pipelines):
The MRs newest known pipeline. With counts based on job result.
-}
viewMrCiStatus :: Text
viewMrCiStatus =
    "CREATE VIEW IF NOT EXISTS view_mr_ci_status AS \
    \SELECT '!' || p.iid AS ref, p.iid, p.pipeline_id, p.status, p.sha, \
    \       p.created_at, p.updated_at, \
    \       (SELECT count(*) FROM pipelines p2 WHERE p2.kind = p.kind AND p2.iid = p.iid) AS pipelines, \
    \       (SELECT count(*) FROM jobs j WHERE j.pipeline_id = p.pipeline_id) AS jobs, \
    \       (SELECT count(*) FROM jobs j WHERE j.pipeline_id = p.pipeline_id \
    \          AND j.status = 'failed' AND j.allow_failure IS NOT 1) AS failed, \
    \       (SELECT count(*) FROM jobs j WHERE j.pipeline_id = p.pipeline_id \
    \          AND j.status = 'failed' AND j.allow_failure IS 1) AS failed_allowed, \
    \       (SELECT count(*) FROM jobs j WHERE j.pipeline_id = p.pipeline_id \
    \          AND j.status IN ('created', 'pending', 'running', 'waiting_for_resource', 'preparing')) AS unfinished, \
    \       p.web_url, p.expire_at \
    \FROM pipelines p \
    \WHERE p.kind = 'mr' \
    \  AND p.pipeline_id = (SELECT max(p2.pipeline_id) FROM pipelines p2 \
    \                        WHERE p2.kind = p.kind AND p2.iid = p.iid)"

{- | One row per job, with the merge request and pipeline it belongs to.
@job_id@ is GitLab's id, the one @--job-log@ takes; @has_log@ says whether
that has been done.

Patch 5 created this as @view_jobs@, and its text must stay as it was;
patch 6 creates it again as @view_mr_jobs@ and gives the name @view_jobs@
to 'viewAllJobs'.
-}
viewJobs :: Text
viewJobs = mrJobsView "view_jobs"

mrJobsView :: Text -> Text
mrJobsView name =
    "CREATE VIEW IF NOT EXISTS "
        <> name
        <> " AS \
           \SELECT '!' || p.iid AS ref, p.iid, p.pipeline_id, "
        <> latestPipeline
        <> ", \
           \       p.status AS pipeline_status, \
           \       j.id AS job_id, j.name, j.stage, j.status, \
           \       (j.allow_failure IS 1) AS allow_failure, j.failure_reason, \
           \       j.started_at, j.finished_at, round(j.duration) AS secs, \
           \       r.description AS runner, \
           \       EXISTS (SELECT 1 FROM job_logs l WHERE l.job_id = j.id) AS has_log, \
           \       j.web_url \
           \FROM jobs j \
           \JOIN pipelines p ON p.pipeline_id = j.pipeline_id \
           \LEFT JOIN runners r ON r.row_id = j.runner_row \
           \WHERE p.kind = 'mr'"

{- | Every job, of any pipeline, including non-mr related ones:
'viewJobs' without the merge request
filter, plus the pipeline's @kind@, @source@ and @git_ref@ to tell master,
nightly and branch jobs apart. @ref@ and @latest@ are NULL where there is no
merge request; @iid@ is the stored one, the pipeline's own id for those.

-}
viewAllJobs :: Text
viewAllJobs =
    "CREATE VIEW IF NOT EXISTS view_jobs AS \
    \SELECT CASE WHEN p.kind = 'mr' THEN '!' || p.iid END AS ref, p.kind, p.iid, p.pipeline_id, \
    \       CASE WHEN p.kind = 'mr' THEN p.pipeline_id = (SELECT max(p2.pipeline_id) FROM pipelines p2 \
    \                                  WHERE p2.kind = p.kind AND p2.iid = p.iid) END AS latest, \
    \       p.status AS pipeline_status, p.source, p.ref AS git_ref, \
    \       j.id AS job_id, j.name, j.stage, j.status, \
    \       (j.allow_failure IS 1) AS allow_failure, j.failure_reason, \
    \       j.started_at, j.finished_at, round(j.duration) AS secs, \
    \       r.description AS runner, \
    \       EXISTS (SELECT 1 FROM job_logs l WHERE l.job_id = j.id) AS has_log, \
    \       j.web_url \
    \FROM jobs j \
    \JOIN pipelines p ON p.pipeline_id = j.pipeline_id \
    \LEFT JOIN runners r ON r.row_id = j.runner_row"

{- | Schema patch 6: @view_mr_jobs@ and @view_jobs@ (see 'viewAllJobs'), then
@view_test_suites@, one row per test job of a pipeline
with a stored test summary. GitLab names a suite after its job and lists
the job's id in @build_ids@; @job_id@ is the first of them.

@ref@ is the merge request (@!123@) and @iid@ its number, both NULL for a
pipeline without one; filter on @iid@, as in the CI views. @latest@ is
'latestPipeline', NULL where there is no merge request to be latest in.
@git_ref@ is the pipeline's branch, tag or merge request ref.
-}
jobAndTestViewStatements :: [Text]
jobAndTestViewStatements =
    [ mrJobsView "view_mr_jobs"
    , "DROP VIEW IF EXISTS view_jobs"
    , viewAllJobs
    , "CREATE VIEW IF NOT EXISTS view_test_suites AS \
      \SELECT CASE WHEN p.kind = 'mr' THEN '!' || p.iid END AS ref, \
      \       CASE WHEN p.kind = 'mr' THEN p.iid END AS iid, \
      \       p.pipeline_id, \
      \       CASE WHEN p.kind = 'mr' THEN p.pipeline_id = (SELECT max(p2.pipeline_id) FROM pipelines p2 \
      \                                  WHERE p2.kind = p.kind AND p2.iid = p.iid) END AS latest, \
      \       p.status AS pipeline_status, p.source, p.ref AS git_ref, p.sha, \
      \       p.created_at, \
      \       json_extract(s.value, '$.name') AS name, \
      \       json_extract(s.value, '$.build_ids[0]') AS job_id, \
      \       json_extract(s.value, '$.total_count') AS total, \
      \       json_extract(s.value, '$.success_count') AS success, \
      \       json_extract(s.value, '$.failed_count') AS failed, \
      \       json_extract(s.value, '$.skipped_count') AS skipped, \
      \       json_extract(s.value, '$.error_count') AS error, \
      \       json_extract(s.value, '$.suite_error') AS suite_error \
      \FROM test_summaries t \
      \JOIN pipelines p ON p.pipeline_id = t.pipeline_id, \
      \     json_each(t.json, '$.test_suites') s"
    ]
