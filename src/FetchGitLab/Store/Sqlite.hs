{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | The SQLite backend.

The shape of what is stored is 'FetchGitLab.Store.Schema'; this module is
the part that talks to the database. Two things about it are worth knowing.

__It writes only what it was told.__ A write states one thing the caller
just learned and touches nothing else: a record upsert leaves the
discussion columns and the note rows exactly as they were, and writing a
discussion leaves the record alone. That is what makes a store safe to
write to without holding a snapshot of it, and it is also what makes a
write cost the same on a full store as on an empty one.

__It shares repeated objects.__ A user arrives again with every note, and a
project has thousands of notes per person. Users and milestones are interned
by their exact JSON, so sharing them cannot change what comes back out: two
copies that differ in any field stay two rows.
-}
module FetchGitLab.Store.Sqlite (
    SqliteStore,
    openSqliteStore,
    closeSqliteStore,
    withSqliteStore,
    sqliteStorePath,
    sqliteTableCounts,
    sqliteTimestampTexts,
    encodeTime,
) where

import Control.Exception (bracket, mask, onException)
import Control.Monad (forM, forM_, when)
import Data.Aeson (Value (..), decodeStrict, encode, fromJSON, toJSON)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time.Clock (UTCTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import Text.Read (readMaybe)

import Database.SQLite.Simple (
    Connection,
    NamedParam ((:=)),
    Only (..),
    Query (..),
    changes,
    close,
    execute,
    executeNamed,
    execute_,
    open,
    query,
    queryNamed,
    query_,
 )

import GitLab.Types (Note)

import FetchGitLab.Store (Entry (..), Record (..), Store)
import FetchGitLab.Store.Class (PipelineState (..), Purged (..), StoreBackend (..))
import FetchGitLab.Store.Schema
import FetchGitLab.Store.Schema.Pipeline (expirySql, nowSql)

-- | An open database, plus the memo tables that keep interning cheap.
data SqliteStore = SqliteStore
    { sqliteStorePath :: FilePath
    , sqliteConn :: Connection
    , sqliteUsers :: IORef (Map Text Int64)
    {- ^ Exact JSON of a user to the row holding it. One lookup per reference
    would otherwise be one round trip per note.
    -}
    , sqliteMilestones :: IORef (Map Text Int64)
    , sqliteLabels :: IORef (Map Text Int64)
    , sqliteRunners :: IORef (Map Text Int64)
    }

-- | Open a store, creating the file and its tables if they are not there.
openSqliteStore :: FilePath -> IO SqliteStore
openSqliteStore path = do
    createDirectoryIfMissing True (takeDirectory path)
    conn <- open path
    -- Write ahead logging suits a run that writes a page or a discussion at a
    -- time and lets readers query while it does, and the foreign keys are worth
    -- enforcing in a store that is all references. NORMAL rather than FULL: a
    -- run that loses its last write to a power cut fetches it again.
    execute_ conn "PRAGMA journal_mode = WAL"
    execute_ conn "PRAGMA synchronous = NORMAL"
    execute_ conn "PRAGMA foreign_keys = ON"
    -- If we open the db concurrently with a writer we are willing to wait a few seconds
    -- rather than failing immediately.
    execute_ conn "PRAGMA busy_timeout = 5000"
    migrate conn
    SqliteStore path conn
        <$> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef Map.empty
        <*> newIORef Map.empty

{- | Fold the write ahead log back into the database before letting go of it,
so that what is left behind is one file rather than three.

@PRAGMA optimize@ first: it re-analyses whatever this run's writes changed
enough to matter, and nothing otherwise. Without statistics the planner
ignores the indexes a patch adds (see 'schemaPatches'), and the @ANALYZE@ a
patch ends with has nothing to record in a store that was empty when it
ran, which every fresh store was.
-}
closeSqliteStore :: SqliteStore -> IO ()
closeSqliteStore st = do
    execute_ (sqliteConn st) "PRAGMA optimize"
    _ <- (query_ (sqliteConn st) "PRAGMA wal_checkpoint(TRUNCATE)" :: IO [(Int, Int, Int)])
    close (sqliteConn st)

withSqliteStore :: FilePath -> (SqliteStore -> IO a) -> IO a
withSqliteStore path = bracket (openSqliteStore path) closeSqliteStore

{- | Update the schema to the current patch level.

The store db records it's current patch level, which we compare against the
binaries.

If the store is newer than the binary do nothing.
Otherwise apply the missing patches (schemaPatches).

We check the schema_version too, but a missmatch there is just an error as
these indicate bigger or breaking changes that need to migrated outside of the
binary.
-}
migrate :: Connection -> IO ()
migrate conn = do
    haveMeta <-
        query_ conn "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'" ::
            IO [Only Int]
    applied <-
        if null haveMeta
            then pure Nothing
            else do
                rows <-
                    query conn "SELECT value FROM meta WHERE key = ?" (Only ("schema_patch_version" :: Text)) ::
                        IO [Only Text]
                pure (case rows of Only v : _ -> readMaybe (T.unpack v); [] -> Nothing)
    case applied of
        Just n | n >= schemaPatchVersion -> checkVersion conn
        _ -> withImmediateTransaction conn $ do
            mapM_ (execute_ conn . Query) schemaStatements
            checkVersion conn
            forM_ (drop (fromMaybe 0 applied) schemaPatches) (applyPatch conn)
            execute
                conn
                "INSERT OR REPLACE INTO meta (key, value) VALUES ('schema_patch_version', ?)"
                (Only (show schemaPatchVersion))

-- | Run one patch, unless its guard says the store does not need it.
applyPatch :: Connection -> SchemaPatch -> IO ()
applyPatch conn patch = do
    wanted <- case patchGuard patch of
        Nothing -> pure True
        Just q -> not . null <$> (query_ conn (Query q) :: IO [Only Int])
    when wanted $ mapM_ (execute_ conn . Query) (patchStatements patch)

{- | A transaction that takes the write lock at @BEGIN@ rather than at the
first write.

Every write here goes through this. @sqlite-simple@\'s 'withTransaction'
issues a deferred @BEGIN@, which takes a read snapshot and only asks for the
write lock later; if another connection has written in between, the upgrade
fails with @SQLITE_BUSY_SNAPSHOT@ and @busy_timeout@ does /not/ wait on it,
because waiting could not help — the snapshot is already stale. An immediate
@BEGIN@ contends for the write lock up front, where @busy_timeout@ does
apply, so a second writer waits its turn instead of failing.
-}
withImmediateTransaction :: Connection -> IO a -> IO a
withImmediateTransaction conn act =
    mask $ \restore -> do
        execute_ conn "BEGIN IMMEDIATE TRANSACTION"
        r <- restore act `onException` execute_ conn "ROLLBACK TRANSACTION"
        execute_ conn "COMMIT TRANSACTION"
        pure r

{- | Simply fail on major schema version differences for now. We might or might not
allow future binaries to add major version migrations.
-}
checkVersion :: Connection -> IO ()
checkVersion conn = do
    stored <- query_ conn "SELECT value FROM meta WHERE key = 'schema_version'"
    case stored of
        [] ->
            execute
                conn
                "INSERT INTO meta (key, value) VALUES ('schema_version', ?)"
                (Only version)
        (Only v : _)
            | v == version -> pure ()
            | otherwise ->
                ioError . userError $
                    "store was written by schema version "
                        <> T.unpack v
                        <> ", this is version "
                        <> show schemaVersion
  where
    version = T.pack (show schemaVersion)

{- | The two timestamp columns of every record, as the text SQLite holds.

For checking that the record's @updated_at@ and its discussion stamp were
written by the same encoder, which is what a text comparison between them
relies on; see 'encodeTime'.
-}
sqliteTimestampTexts :: SqliteStore -> IO [(Text, Int, Maybe Text, Maybe Text)]
sqliteTimestampTexts st =
    query_
        (sqliteConn st)
        "SELECT kind, iid, updated_at, discussion_updated_at FROM records ORDER BY kind, iid"

{- | How many rows each table holds. Says whether the sharing the schema is
built around is actually happening.
-}
sqliteTableCounts :: SqliteStore -> IO [(Text, Int)]
sqliteTableCounts st = tableCounts st tables
  where
    tables =
        [ "records"
        , "notes"
        , "users"
        , "milestones"
        , "labels"
        , "record_users"
        , "note_users"
        , "pipelines"
        , "jobs"
        , "runners"
        , "commits"
        , "job_logs"
        , "test_summaries"
        ]

{- | The row counts of the three tables a purge removes from, which is how a
purge is counted: @changes()@ sees neither the rows a cascade took nor the
ones a trigger did.
-}
ciCounts :: SqliteStore -> IO [(Text, Int)]
ciCounts st = tableCounts st ["pipelines", "jobs", "job_logs"]

{- | @count(*)@ of each table named. The names are literals in this module, so
there is nothing for a caller to smuggle into the statement.
-}
tableCounts :: SqliteStore -> [Text] -> IO [(Text, Int)]
tableCounts st =
    traverse $ \t -> do
        rows <- query_ (sqliteConn st) (Query ("SELECT count(*) FROM " <> t))
        pure (t, case rows of (Only n : _) -> n; [] -> 0)

instance StoreBackend SqliteStore where
    storeName _ = "sqlite"
    storeLocation = T.pack . sqliteStorePath

    storeLoad :: forall a. (Record a) => SqliteStore -> IO (Either String (Store a))
    storeLoad st = loadKind Everything st (recordKind (Proxy :: Proxy a))

    storeLookup :: forall a. (Record a) => SqliteStore -> Int -> IO (Either String (Maybe (Entry a)))
    storeLookup st iid =
        fmap (Map.lookup iid)
            <$> (loadKind (JustOne iid) st (recordKind (Proxy :: Proxy a)) :: IO (Either String (Store a)))

    storeWriteRecords :: forall a. (Record a) => SqliteStore -> [a] -> IO ()
    storeWriteRecords _ [] = pure ()
    storeWriteRecords st records =
        withImmediateTransaction (sqliteConn st) $
            mapM_ (writeRecord st (recordKind (Proxy :: Proxy a))) records

    storeWriteDiscussion ::
        forall a. (Record a) => SqliteStore -> Proxy a -> Int -> Maybe Text -> [Note] -> IO ()
    storeWriteDiscussion st proxy iid stamp notes = do
        let conn = sqliteConn st
            kind = recordKind proxy
        withImmediateTransaction conn $ do
            execute conn "DELETE FROM note_users WHERE kind = ? AND iid = ?" (kind, iid)
            execute conn "DELETE FROM notes WHERE kind = ? AND iid = ?" (kind, iid)
            forM_ (zip [0 :: Int ..] notes) (uncurry (writeNote st kind iid))
            -- The stamp the caller planned against, never the row's own updated_at:
            -- the record may have moved since, and these notes do not cover that.
            execute
                conn
                "UPDATE records SET discussion_updated_at = ? WHERE kind = ? AND iid = ?"
                (stamp, kind, iid)

    storeDiscussionPlan :: forall a. (Record a) => SqliteStore -> Proxy a -> IO [(Int, Maybe Text)]
    storeDiscussionPlan st proxy =
        -- 'IS NOT' rather than '<>' so that a NULL stamp — never fetched, or
        -- cleared — reads as stale without a flag column to say so. The extra
        -- 'IS NULL' is for the record GitLab sent no updated_at for at all: both
        -- columns NULL would otherwise compare equal and its discussion would
        -- never be fetched.
        --
        -- Ordering is 'approximately' newest first: the text is what aeson wrote
        -- and does not sort chronologically (see 'encodeTime'), so records within
        -- a second of each other can come in either order. Nothing depends on
        -- more than that -- it decides what an interrupted run got to first.
        query
            (sqliteConn st)
            "SELECT iid, updated_at FROM records \
            \ WHERE kind = ? AND (discussion_updated_at IS NULL OR discussion_updated_at IS NOT updated_at) \
            \ ORDER BY updated_at DESC"
            (Only (recordKind proxy))

    storeRecordCount :: forall a. (Record a) => SqliteStore -> Proxy a -> IO Int
    storeRecordCount st proxy = do
        rows <-
            query (sqliteConn st) "SELECT count(*) FROM records WHERE kind = ?" (Only (recordKind proxy))
        pure (case rows of Only n : _ -> n; [] -> 0)

    storeLatestUpdate :: forall a. (Record a) => SqliteStore -> Proxy a -> IO (Maybe UTCTime)
    storeLatestUpdate st proxy = do
        -- MAX over text aeson wrote, so this can be under a second out; see
        -- 'encodeTime'. 'FetchGitLab.Fetch.fetchSince' rewinds a whole second
        -- before asking GitLab, which covers it.
        rows <-
            query
                (sqliteConn st)
                "SELECT MAX(updated_at) FROM records WHERE kind = ?"
                (Only (recordKind proxy)) ::
                IO [Only (Maybe Text)]
        pure $ case rows of
            Only (Just t) : _ -> either (const Nothing) Just (decodeTime t)
            _ -> Nothing

    storeRecordVersions ::
        forall a. (Record a) => SqliteStore -> Proxy a -> [Int] -> IO (Map Int (Maybe UTCTime))
    storeRecordVersions _ _ [] = pure Map.empty
    storeRecordVersions st proxy iids = do
        -- The keys go into the statement rather than into parameters because
        -- there is one per record of a page and sqlite-simple binds a fixed row;
        -- they are 'Int', so there is nothing a literal could smuggle in.
        rows <-
            query
                (sqliteConn st)
                ( Query
                    ( "SELECT iid, updated_at FROM records WHERE kind = ? AND iid IN ("
                        <> T.intercalate "," (map (T.pack . show) iids)
                        <> ")"
                    )
                )
                (Only (recordKind proxy)) ::
                IO [(Int, Maybe Text)]
        pure (Map.fromList [(iid, t >>= either (const Nothing) Just . decodeTime) | (iid, t) <- rows])

    storeClearDiscussionStamps :: forall a. (Record a) => SqliteStore -> Proxy a -> IO Int
    storeClearDiscussionStamps st proxy = do
        let conn = sqliteConn st
        withImmediateTransaction conn $ do
            execute
                conn
                "UPDATE records SET discussion_updated_at = NULL \
                \ WHERE kind = ? AND discussion_updated_at IS NOT NULL"
                (Only (recordKind proxy))
            changes conn

    storeWritePipelines :: SqliteStore -> Text -> Int -> [(Value, [Value])] -> IO ()
    storeWritePipelines st kind iid pairs =
        withImmediateTransaction (sqliteConn st) $
            forM_ pairs $
                \(p, jobs) -> writePipeline st kind iid p jobs

    storeWriteTestSummary :: SqliteStore -> Int -> Maybe Text -> Maybe Value -> IO ()
    storeWriteTestSummary st pid stamp summary =
        withImmediateTransaction (sqliteConn st) $
            execute
                (sqliteConn st)
                "INSERT INTO test_summaries (pipeline_id, pipeline_updated_at, json) VALUES (?, ?, ?) \
                \ ON CONFLICT (pipeline_id) DO UPDATE SET pipeline_updated_at = excluded.pipeline_updated_at, \
                \   json = coalesce(excluded.json, test_summaries.json)"
                (pid, stamp, encodeText <$> summary)

    storePipelineStates :: SqliteStore -> [Int] -> IO (Map Int PipelineState)
    storePipelineStates _ [] = pure Map.empty
    storePipelineStates st pids = do
        -- Literal ids, as in 'storeRecordVersions': one per pipeline listed.
        rows <-
            query_
                (sqliteConn st)
                ( Query
                    ( "SELECT p.pipeline_id, p.status, p.updated_at, \
                      \       (SELECT t.pipeline_updated_at FROM test_summaries t WHERE t.pipeline_id = p.pipeline_id) \
                      \ FROM pipelines p WHERE p.pipeline_id IN ("
                        <> T.intercalate "," (map (T.pack . show) pids)
                        <> ")"
                    )
                ) ::
                IO [(Int, Maybe Text, Maybe Text, Maybe Text)]
        pure (Map.fromList [(pid, PipelineState status updated checked) | (pid, status, updated, checked) <- rows])

    storeHasJob :: SqliteStore -> Int -> IO Bool
    storeHasJob st jid = do
        rows <- query (sqliteConn st) "SELECT 1 FROM jobs WHERE id = ?" (Only jid)
        pure (not (null (rows :: [Only Int])))

    storeWriteJobLog :: SqliteStore -> Int -> Text -> IO ()
    storeWriteJobLog st jid body =
        withImmediateTransaction conn $ do
            execute
                conn
                ( Query
                    ( "INSERT INTO job_logs (job_id, expire_at, raw_log) VALUES (?, "
                        <> expirySql
                        <> ", ?) \
                           \ ON CONFLICT (job_id) DO UPDATE SET \
                           \   raw_log = excluded.raw_log, expire_at = excluded.expire_at"
                    )
                )
                (jid, body)
            -- The log's expiry has to carry the merge request it hangs off with it,
            -- and the whole of it.
            --
            -- A log is deleted with its job, by cascade and by trigger, so a log
            -- fetched on day 29 of its job's life would be gone on day 30 however
            -- long its own expiry said. And renewing only the one job, or only its
            -- pipeline, would leave the merge request holding a partial set of
            -- pipelines and jobs, which reads as "this merge request ran one
            -- pipeline" rather than as "the rest expired". @--pipelines MR@ is the
            -- unit a fetch works in, so it is the unit expiry works in too.
            --
            -- Extend, never shorten: a row already expiring later than the log keeps
            -- its date. The fixed-width format of 'expirySql' is what lets that be a
            -- text comparison; a NULL is treated as the earliest date there is,
            -- since NULL means the purge will not remove the row but says nothing
            -- about when it should.
            owner <-
                query
                    conn
                    "SELECT p.kind, p.iid FROM jobs j \
                    \ JOIN pipelines p ON p.pipeline_id = j.pipeline_id \
                    \ WHERE j.id = ?"
                    (Only jid) ::
                    IO [(Text, Int)]
            forM_ owner $ \(kind, iid) -> do
                execute
                    conn
                    ( Query
                        ( "UPDATE pipelines SET expire_at = "
                            <> expirySql
                            <> " \
                               \ WHERE kind = ? AND iid = ? \
                               \   AND (expire_at IS NULL OR expire_at < "
                            <> expirySql
                            <> ")"
                        )
                    )
                    (kind, iid)
                execute
                    conn
                    ( Query
                        ( "UPDATE jobs SET expire_at = "
                            <> expirySql
                            <> " \
                               \ WHERE pipeline_id IN (SELECT pipeline_id FROM pipelines WHERE kind = ? AND iid = ?) \
                               \   AND (expire_at IS NULL OR expire_at < "
                            <> expirySql
                            <> ")"
                        )
                    )
                    (kind, iid)
      where
        conn = sqliteConn st

    storePurgeExpired :: SqliteStore -> IO Purged
    storePurgeExpired st = withImmediateTransaction conn $ do
        before <- ciCounts st
        -- Logs first, then jobs — which take their own logs with them by cascade
        -- and by trigger — then the pipelines that have no job left. A pipeline
        -- that still has jobs is kept whatever its own date says: jobs reference
        -- pipelines with no ON DELETE action and this connection enforces foreign
        -- keys, so deleting it would fail the whole transaction.
        execute_ conn (Query ("DELETE FROM job_logs WHERE expire_at <= " <> nowSql))
        execute_ conn (Query ("DELETE FROM jobs WHERE expire_at IS NOT NULL AND expire_at <= " <> nowSql))
        execute_
            conn
            ( Query
                ( "DELETE FROM pipelines \
                  \ WHERE expire_at IS NOT NULL AND expire_at <= "
                    <> nowSql
                    <> " \
                       \   AND NOT EXISTS (SELECT 1 FROM jobs j WHERE j.pipeline_id = pipelines.pipeline_id)"
                )
            )
        after <- ciCounts st
        let purged =
                Purged
                    { purgedPipelines = countOf "pipelines" before - countOf "pipelines" after
                    , purgedJobs = countOf "jobs" before - countOf "jobs" after
                    , purgedJobLogs = countOf "job_logs" before - countOf "job_logs" after
                    }
        -- Commits and runners are referenced from jobs and from nowhere else, so
        -- a job going can leave one unreferenced. Users are shared with the
        -- records and the notes and are never touched here.
        --
        -- Only when something went: these are two scans of the jobs table that a
        -- run which purged nothing has no reason to pay for.
        when (purged /= Purged 0 0 0) $ do
            execute_
                conn
                "DELETE FROM commits \
                \ WHERE NOT EXISTS (SELECT 1 FROM jobs j WHERE j.commit_id = commits.commit_id)"
            execute_
                conn
                "DELETE FROM runners \
                \ WHERE NOT EXISTS (SELECT 1 FROM jobs j WHERE j.runner_row = runners.row_id)"
            -- The interning cache maps a runner's JSON to a row that may be one of
            -- those just deleted, and SQLite hands a deleted row's id out again.
            -- Dropping the cache costs one query per runner the rest of the command
            -- writes, and a purge happens once per run.
            atomicModifyIORef' (sqliteRunners st) (const (Map.empty, ()))
        -- No VACUUM: the pages this frees are reused by whatever the store grows
        -- into next, and rewriting a gigabyte to hand a few megabytes back to the
        -- filesystem is not a thing to do at every startup.
        pure purged
      where
        conn = sqliteConn st

        countOf t counts = fromMaybe 0 (lookup t counts)

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

{- | Replace one record and the users and labels it refers to.

What it deliberately does not touch is the discussion: neither the note rows
nor @discussion_updated_at@ appear here, so a fresh record arrives with a
NULL stamp (which is what puts it in 'storeDiscussionPlan') and a record
already in the store keeps whatever discussion it had. A run therefore never
has to hold notes in order to write a record back, and a page written while
another run is fetching notes cannot undo them.

Users and labels are deleted and written again rather than diffed: a record
that came back from GitLab may have gained or lost assignees and labels.
-}
writeRecord :: (Record a) => SqliteStore -> Text -> a -> IO ()
writeRecord st kind record = do
    let iid = recordKey record
        value = toJSON record
        (rest, lifted) = splitObject recordSpec value
        conn = sqliteConn st

    milestoneRow <- traverse (internMilestone st) (liftedMilestone lifted)

    execute conn "DELETE FROM record_users WHERE kind = ? AND iid = ?" (kind, iid)
    execute conn "DELETE FROM record_labels WHERE kind = ? AND iid = ?" (kind, iid)

    executeNamed
        conn
        "INSERT INTO records (kind, iid, milestone_row, rest, lifted) \
        \ VALUES (:kind, :iid, :milestone_row, :rest, :lifted) \
        \ ON CONFLICT(kind, iid) DO UPDATE SET \
        \   rest = excluded.rest, \
        \   lifted = excluded.lifted, \
        \   milestone_row = excluded.milestone_row"
        [ ":kind" := kind
        , ":iid" := iid
        , ":milestone_row" := milestoneRow
        , ":rest" := encodeText rest
        , ":lifted" := encodeText (toJSON (liftedKeys lifted))
        ]

    forM_ (liftedUsers lifted) $ \(field, position, user) -> do
        row <- internUser st user
        execute
            conn
            "INSERT OR REPLACE INTO record_users (kind, iid, field, position, user_row) \
            \ VALUES (?, ?, ?, ?, ?)"
            (kind, iid, field, position, row)

    forM_ (liftedLabels lifted) $ \(position, name) -> do
        label <- internLabel st name
        execute
            conn
            "INSERT OR REPLACE INTO record_labels (kind, iid, position, label_id) VALUES (?, ?, ?, ?)"
            (kind, iid, position, label)

writeNote :: SqliteStore -> Text -> Int -> Int -> Note -> IO ()
writeNote st kind iid position note = do
    let value = toJSON note
        (rest, lifted) = splitObject noteSpec value
        conn = sqliteConn st

    executeNamed
        conn
        "INSERT OR REPLACE INTO notes (kind, iid, position, rest, lifted) \
        \ VALUES (:kind, :iid, :position, :rest, :lifted)"
        [ ":kind" := kind
        , ":iid" := iid
        , ":position" := position
        , ":rest" := encodeText rest
        , ":lifted" := encodeText (toJSON (liftedKeys lifted))
        ]

    forM_ (liftedUsers lifted) $ \(field, _, user) -> do
        row <- internUser st user
        execute
            conn
            "INSERT OR REPLACE INTO note_users (kind, iid, position, field, user_row) \
            \ VALUES (?, ?, ?, ?, ?)"
            (kind, iid, position, field, row)

{- | Write one pipeline and the jobs it ran.

The pipeline object is kept verbatim: the pipelines endpoints return the
basic pipeline object with nothing shared in it worth lifting.

An upsert, not @INSERT OR REPLACE@, for the reason 'writeJob' is one: a
replace deletes the row, and the test summary goes with it by cascade.
Kind @pipeline@ means "owner unknown" and keeps whatever owner the row
already had, so a project-wide listing never unfiles a merge request's
pipeline.

@expire_at@ is set from scratch rather than kept, so fetching a merge
request's pipelines again is what keeps them: a pipeline is held for
'retentionInterval' from the last time it was seen, not from the first.
-}
writePipeline :: SqliteStore -> Text -> Int -> Value -> [Value] -> IO ()
writePipeline st kind iid p jobs = do
    pid <- require "pipeline id" (fieldOf "id" p :: Maybe Int)
    execute
        (sqliteConn st)
        ( Query
            ( "INSERT INTO pipelines (pipeline_id, kind, iid, rest, expire_at) \
              \ VALUES (?, ?, ?, ?, "
                <> expirySql
                <> ") \
                   \ ON CONFLICT (pipeline_id) DO UPDATE SET \
                   \  kind = CASE WHEN excluded.kind = 'pipeline' THEN pipelines.kind ELSE excluded.kind END, \
                   \  iid = CASE WHEN excluded.kind = 'pipeline' THEN pipelines.iid ELSE excluded.iid END, \
                   \  rest = excluded.rest, expire_at = excluded.expire_at"
            )
        )
        (pid, kind, iid, encodeText p)
    forM_ jobs (writeJob st pid)

{- | Write one job of a pipeline.

An upsert, not @INSERT OR REPLACE@: a replace deletes the row it replaces,
and deleting a job deletes its log (see "FetchGitLab.Store.Schema.Pipeline").
It also keeps @job_row@ the same across rewrites.

Four objects leave the job before it is stored: its @user@ and @runner@ are
interned, its @commit@ is written to the commits table, and its nested
@pipeline@ is dropped outright — it is a shorter copy of the row every
field of which the pipelines table already holds. As in 'splitObject', a
key is only taken out when it holds the shape expected of it, so a @null@
runner stays in @rest@ and the NULL reference column is what says nothing
was lifted.

The scalars a job is queried by are copied into real columns; @rest@ keeps
them too, so it stays the object the server sent minus exactly the four
lifted keys.

The upsert renews @expire_at@ as well, so a refetched job is kept from now
rather than from when it was first seen — the same rule
'writePipeline' follows.
-}
writeJob :: SqliteStore -> Int -> Value -> IO ()
writeJob st pid v = do
    jid <- require "job id" (fieldOf "id" v :: Maybe Int)
    status <- require "job status" (fieldOf "status" v)
    stage <- require "job stage" (fieldOf "stage" v)
    createdAt <- require "job created_at" (fieldOf "created_at" v)

    userRow <- traverse (internUser st) (objectAt "user" v)
    runnerRow <- traverse (internRunner st) (objectAt "runner" v)
    commitId <- forM (objectAt "commit" v) $ \c -> do
        cid <- require "commit id" (fieldOf "id" c :: Maybe Text)
        execute
            conn
            "INSERT OR IGNORE INTO commits (commit_id, author_name, author_email, json) \
            \ VALUES (?, ?, ?, ?)"
            (cid, fieldOf "author_name" c :: Maybe Text, fieldOf "author_email" c :: Maybe Text, encodeText c)
        pure cid

    executeNamed
        conn
        ( Query
            ( "INSERT INTO jobs \
              \ (id, pipeline_id, user_row, runner_row, commit_id, status, stage, \
              \  created_at, started_at, finished_at, erased_at, duration, queued_duration, rest, \
              \  expire_at) \
              \ VALUES \
              \ (:id, :pipeline_id, :user_row, :runner_row, :commit_id, :status, :stage, \
              \  :created_at, :started_at, :finished_at, :erased_at, :duration, :queued_duration, \
              \  :rest, "
                <> expirySql
                <> ") \
                   \ ON CONFLICT (id) DO UPDATE SET \
                   \  pipeline_id = excluded.pipeline_id, user_row = excluded.user_row, \
                   \  runner_row = excluded.runner_row, commit_id = excluded.commit_id, \
                   \  status = excluded.status, stage = excluded.stage, \
                   \  created_at = excluded.created_at, started_at = excluded.started_at, \
                   \  finished_at = excluded.finished_at, erased_at = excluded.erased_at, \
                   \  duration = excluded.duration, queued_duration = excluded.queued_duration, \
                   \  rest = excluded.rest, expire_at = excluded.expire_at"
            )
        )
        [ ":id" := jid
        , ":pipeline_id" := pid
        , ":user_row" := userRow
        , ":runner_row" := runnerRow
        , ":commit_id" := commitId
        , ":status" := (status :: Text)
        , ":stage" := (stage :: Text)
        , ":created_at" := (createdAt :: Text)
        , ":started_at" := (fieldOf "started_at" v :: Maybe Text)
        , ":finished_at" := (fieldOf "finished_at" v :: Maybe Text)
        , ":erased_at" := (fieldOf "erased_at" v :: Maybe Text)
        , ":duration" := (fieldOf "duration" v :: Maybe Double)
        , ":queued_duration" := (fieldOf "queued_duration" v :: Maybe Double)
        , ":rest" := encodeText rest
        ]
  where
    conn = sqliteConn st

    lifted = [k | k <- ["user", "pipeline", "commit", "runner"], Just _ <- [objectAt k v]]
    rest = case v of
        Object o -> Object (foldr (KM.delete . Key.fromText) o lifted)
        other -> other

{- | A field of a JSON object, at whatever type the caller expects; 'Nothing'
for a missing field, a @null@, or a value of another shape.
-}
fieldOf :: (Aeson.FromJSON a) => Text -> Value -> Maybe a
fieldOf k = Aeson.parseMaybe (Aeson.withObject "object" (Aeson..: Key.fromText k))

-- | A field holding a JSON object, and nothing of any other shape.
objectAt :: Text -> Value -> Maybe Value
objectAt k v = case fieldOf k v of
    Just o@(Object _) -> Just o
    _ -> Nothing

require :: Text -> Maybe a -> IO a
require what = maybe (ioError (userError ("GitLab sent no usable " <> T.unpack what))) pure

-- ---------------------------------------------------------------------------
-- Interning
-- ---------------------------------------------------------------------------

internUser :: SqliteStore -> Value -> IO Int64
internUser st value = intern (sqliteUsers st) key $ do
    execute (sqliteConn st) "INSERT OR IGNORE INTO users (json) VALUES (?)" (Only key)
    rowOf (sqliteConn st) "SELECT row_id FROM users WHERE json = ?" key
  where
    key = encodeText value

internMilestone :: SqliteStore -> Value -> IO Int64
internMilestone st value = intern (sqliteMilestones st) key $ do
    execute (sqliteConn st) "INSERT OR IGNORE INTO milestones (json) VALUES (?)" (Only key)
    rowOf (sqliteConn st) "SELECT row_id FROM milestones WHERE json = ?" key
  where
    key = encodeText value

{- | Interned by exact JSON like a user, deliberately not by the runner's id:
a runner object is mutable state — @online@, @status@ — and each job keeps
the state its fetch observed.
-}
internRunner :: SqliteStore -> Value -> IO Int64
internRunner st value = intern (sqliteRunners st) key $ do
    execute (sqliteConn st) "INSERT OR IGNORE INTO runners (json) VALUES (?)" (Only key)
    rowOf (sqliteConn st) "SELECT row_id FROM runners WHERE json = ?" key
  where
    key = encodeText value

internLabel :: SqliteStore -> Text -> IO Int64
internLabel st name = intern (sqliteLabels st) name $ do
    execute (sqliteConn st) "INSERT OR IGNORE INTO labels (name) VALUES (?)" (Only name)
    rowOf (sqliteConn st) "SELECT label_id FROM labels WHERE name = ?" name

{- | Look a value up in the memo table, and put it in the database if it is not
there yet. The insert is @OR IGNORE@ plus a select rather than a
@lastInsertRowId@, because the row may already be there from an earlier run.
-}
intern :: IORef (Map Text Int64) -> Text -> IO Int64 -> IO Int64
intern ref key insert = do
    cached <- readIORef ref
    case Map.lookup key cached of
        Just row -> pure row
        Nothing -> do
            row <- insert
            atomicModifyIORef' ref (\m -> (Map.insert key row m, ()))
            pure row

rowOf :: Connection -> Query -> Text -> IO Int64
rowOf conn q key = do
    rows <- query conn q (Only key)
    case rows of
        (Only row : _) -> pure row
        [] -> ioError (userError ("row vanished after insert: " <> show q))

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- | How much of a kind a load is after.
data Selection
    = {- | Every record of the kind, which is what a reader dumping a project
      wants.
      -}
      Everything
    | {- | The one record with this @iid@, which is what a reader after a single
      ticket wants. It travels as a bound parameter that every query tests, so
      the assembling below stays one code path rather than two.
      -}
      JustOne Int

{- | Read records of one kind, with their discussions.

Everything is fetched in a handful of queries and joined up in memory. One
query per record would be tens of thousands of round trips for a project the
size of GHC's. This is the reader's path and it holds the whole result; a
run does not use it, and asks 'storeDiscussionPlan' what it still owes
instead.
-}
loadKind ::
    forall a. (Record a) => Selection -> SqliteStore -> Text -> IO (Either String (Store a))
loadKind selection st kind = do
    let conn = sqliteConn st
        -- NULL means "no restriction", so a query can name the parameter and be
        -- read either way. Everything below is filtered by it, notes included.
        only = case selection of
            Everything -> Nothing
            JustOne iid -> Just iid
        params = [":kind" := kind, ":iid" := only]

    users <- Map.fromList <$> (query_ conn "SELECT row_id, json FROM users" :: IO [(Int64, Text)])
    milestones <-
        Map.fromList <$> (query_ conn "SELECT row_id, json FROM milestones" :: IO [(Int64, Text)])

    recordRows <-
        queryNamed
            conn
            "SELECT iid, milestone_row, discussion_updated_at, rest, lifted \
            \ FROM records WHERE kind = :kind AND (:iid IS NULL OR iid = :iid)"
            params ::
            IO [(Int, Maybe Int64, Maybe Text, Text, Text)]

    userRefs <-
        queryNamed
            conn
            "SELECT iid, field, position, user_row FROM record_users \
            \ WHERE kind = :kind AND (:iid IS NULL OR iid = :iid)"
            params ::
            IO [(Int, Text, Int, Int64)]

    labelRefs <-
        queryNamed
            conn
            "SELECT r.iid, r.position, l.name FROM record_labels r \
            \ JOIN labels l ON l.label_id = r.label_id \
            \ WHERE r.kind = :kind AND (:iid IS NULL OR r.iid = :iid)"
            params ::
            IO [(Int, Int, Text)]

    -- The two heavy queries of the six: notes outnumber records by an order of
    -- magnitude and carry the bodies. A reader after one ticket pays for one
    -- ticket, which is what 'JustOne' is for.
    noteRows <-
        queryNamed
            conn
            "SELECT iid, position, rest, lifted FROM notes \
            \ WHERE kind = :kind AND (:iid IS NULL OR iid = :iid) \
            \ ORDER BY iid, position"
            params ::
            IO [(Int, Int, Text, Text)]

    noteRefs <-
        queryNamed
            conn
            "SELECT iid, position, field, user_row FROM note_users \
            \ WHERE kind = :kind AND (:iid IS NULL OR iid = :iid)"
            params ::
            IO [(Int, Int, Text, Int64)]

    let usersByIid = groupOn (\(iid, _, _, _) -> iid) userRefs
        labelsByIid = groupOn (\(iid, _, _) -> iid) labelRefs
        refsByNote = groupOn (\(iid, pos, _, _) -> (iid, pos)) noteRefs
        notesByIid = groupOn (\(iid, _, _, _) -> iid) noteRows

        resolveUser :: Int64 -> Either String Value
        resolveUser row = look "user" users row

        notesFor iid =
            forM (Map.findWithDefault [] iid notesByIid) $ \(_, pos, rest, lifted) -> do
                base <- decodeValue "note" rest
                keys <- decodeValue "note lifted keys" lifted >>= parseValue "lifted keys"
                refs <-
                    traverse
                        (\(_, _, f, r) -> (,) f <$> resolveUser r)
                        (Map.findWithDefault [] (iid, pos) refsByNote)
                let l =
                        Lifted
                            { liftedUsers = [(f, 0, v) | (f, v) <- refs]
                            , liftedMilestone = Nothing
                            , liftedLabels = []
                            , liftedKeys = keys
                            }
                parseValue "note" (spliceObject noteSpec l base) :: Either String Note

    pure $
        fmap Map.fromList . forM recordRows $
            \(iid, milestoneRow, discussionFor, rest, lifted) -> do
                base <- decodeValue "record" rest
                keys <- decodeValue "record lifted keys" lifted >>= parseValue "lifted keys"
                refs <-
                    traverse
                        (\(_, f, p, r) -> (,,) f p <$> resolveUser r)
                        (Map.findWithDefault [] iid usersByIid)
                milestone <- traverse (look "milestone" milestones) milestoneRow
                let l =
                        Lifted
                            { liftedUsers = refs
                            , liftedMilestone = milestone
                            , liftedLabels = sortOn fst [(p, n) | (_, p, n) <- Map.findWithDefault [] iid labelsByIid]
                            , liftedKeys = keys
                            }
                record <- parseValue "record" (spliceObject recordSpec l base) :: Either String a
                -- What the notes table actually holds, rather than what the stamp
                -- implies: after @--clear-timestamp@ a record has no stamp and its notes
                -- are still there to be read.
                notes <- notesFor iid
                discussionAt <- traverse decodeTime discussionFor
                pure
                    ( iid
                    , Entry
                        { entryRecord = record
                        , entryNotes = if null notes then Nothing else Just notes
                        , entryDiscussionFor = discussionAt
                        }
                    )
  where
    look what m row = case Map.lookup row m of
        Just json -> decodeValue what json
        Nothing -> Left (T.unpack kind <> ": no " <> what <> " row " <> show row)

    groupOn f = Map.fromListWith (flip (<>)) . map (\x -> (f x, [x]))

decodeValue :: String -> Text -> Either String Value
decodeValue what t = case decodeStrict (encodeUtf8 t) of
    Just v -> Right v
    Nothing -> Left (what <> ": stored JSON did not parse")

parseValue :: (Aeson.FromJSON b) => String -> Value -> Either String b
parseValue what v = case fromJSON v of
    Aeson.Success x -> Right x
    Aeson.Error err -> Left (what <> ": " <> err)

encodeText :: Value -> Text
encodeText = decodeUtf8 . BL.toStrict . encode

{- | Timestamps go in as the text aeson would have written, without its quotes,
so that the column reads well in a query and still comes back bit for bit.
Using aeson's own printer and parser is the point: the staleness check
compares this against the record's @updated_at@, and a timestamp that lost a
digit on the way through would make every run refetch every discussion.

== Every timestamp column must be written by this same encoder

The record's @updated_at@ column is not GitLab's text either: it is
@json_extract@ed from @rest@, which is 'toJSON' of the parsed record, so it
too has been through aeson. That is the only reason the two columns can be
compared at all, because aeson does not preserve GitLab's format: it drops
trailing zeros from the fraction, writing @.550Z@ as @.55Z@ and @.000Z@ as
plain @Z@ (4,298 of the 42,929 records in the real store carry a trimmed
fraction; none of them disagree with their stamp). Any new path that writes
or compares a timestamp column — a staleness check done in SQL, a record
stored from raw JSON rather than through 'toJSON', a stamp copied from
GitLab's text — must produce the same text as this function or the check
silently reports every discussion stale.

A consequence to keep in mind when querying: the trimmed text does not sort
chronologically. @Z@ collates after @.@ and after every digit, so @…:45Z@
sorts after @…:45.9Z@ and @…:45.5Z@ after @…:45.55Z@. @MAX(updated_at)@ and
@ORDER BY updated_at@ are therefore off by less than a second, which
'FetchGitLab.Fetch.fetchSince' tolerates by rewinding a full second; any
use that needs exact order has to parse first.
-}
encodeTime :: UTCTime -> Text
encodeTime = T.dropAround (== '"') . decodeUtf8 . BL.toStrict . encode

decodeTime :: Text -> Either String UTCTime
decodeTime t = case decodeStrict (encodeUtf8 ("\"" <> t <> "\"")) of
    Just u -> Right u
    Nothing -> Left ("could not read stored timestamp " <> show t)
