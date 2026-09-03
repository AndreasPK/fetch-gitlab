{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for the store and the fetching around it.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Aeson (FromJSON, Value, eitherDecode, encode, object, toJSON, (.=))
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (isInfixOf, nub, sort, sortOn)
import Data.Maybe (isJust)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, getCurrentTime)
import GHC.Clock (getMonotonicTime)
import Control.Monad (forM, forM_)
import Control.Monad.IO.Class (liftIO)
import System.Directory (doesFileExist, renameFile, setModificationTime)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.Process (getCurrentPid, getPid, spawnProcess, waitForProcess)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import Network.HTTP.Client (HttpException, Response, httpLbs, parseRequest)
import Network.HTTP.Types.Status (mkStatus, status200, status503)

import GitLab.Types (GitLabError (..), Issue (..), MergeRequest (..), Note (..))
import GitLab (unexpectedStatus)

import Log (LogLevel (..), LogT, mkLogger, runLogT)
import Log.Internal.Logger (withLogger)
import Log.Backend.StandardOutput (withStdOutLogger)

import FetchGitLab.ClearTimestamp (clearTimestamps)
import FetchGitLab.Fetch (challengeDetail, challengeWaits, readToken, waitOutChallenge)
import FetchGitLab.Options (Backend (..), parseBackend)
import FetchGitLab.Store.Backend (StoreSpec (..), detectSpec)
import FetchGitLab.Lock
  ( LockBusy (..)
  , LockInfo (..)
  , lockPath
  , readLockInfo
  , withStoreLocks
  )
import FetchGitLab.RateLimit (newRateLimiter, rateLimitedManager, waitTurn)
import FetchGitLab.Since (Since (..), Unit (..), parseSince, resolveSince)
import FetchGitLab.Store
  ( Entry (..)
  , Record (..)
  , Store
  , needsDiscussion
  )
import FetchGitLab.Store.Class (StoreBackend (..))
import FetchGitLab.Store.Schema
  ( Lifted (..)
  , noteSpec
  , recordSpec
  , spliceObject
  , splitObject
  )
import FetchGitLab.Store.Sqlite
  ( SqliteStore
  , encodeTime
  , sqliteTableCounts
  , sqliteTimestampTexts
  , withSqliteStore
  )

import qualified Database.SQLite.Simple as SQL

-- | Normally the test suite, but 'lockExcludesAnotherProcess' re-runs this
-- executable as its own lock holding child.
main :: IO ()
main = do
  args <- getArgs
  case args of
    [flag, store, ready, release] | flag == holdLockFlag -> holdLock store ready release
    _ -> defaultMain tests

tests :: TestTree
tests =
  testGroup
    "fetch-gitlab"
    [ testGroup
        "store"
        [ testCase "writing a record again replaces it" recordWriteReplaces
        , testCase "the store says where a run resumes from" latestUpdateIsNewest
        ]
    , testGroup
        "discussions"
        [ testCase "an entry with a discussion roundtrips" discussionRoundtrips
        , testCase "rewriting a record keeps the discussion we already have" recordWriteKeepsDiscussion
        , testCase "a changed record makes its discussion stale" changedRecordIsStale
        , testCase "a second run over unchanged records asks for nothing" secondRunAsksForNothing
        , testCase "only the changed record is asked about again" onlyChangedIsRefetched
        ]
    , testGroup
        "already fetched"
        [ testCase "re-fetched records are counted as current" countsUnchangedRecords
        , testCase "a changed record does not count as current" changedIsNotCurrent
        ]
    , testGroup
        "sqlite backend"
        [ testCase "issues survive a round trip" (sqliteRoundtrips (Proxy :: Proxy Issue) "test/data/issues.jsonl")
        , testCase "merge requests survive a round trip" (sqliteRoundtrips (Proxy :: Proxy MergeRequest) "test/data/mrs.jsonl")
        , testCase "an empty store reads back empty" sqliteStartsEmpty
        , testCase "a write touches only what it names" sqliteWritesOnlyWhatItNames
        , testCase "reopening finds what was written" sqliteSurvivesReopen
        , testCase "repeated users are shared, not copied" sqliteSharesUsers
        , testCase "the plan agrees with what a reader calls stale" planAgreesWithReader
        , testCase "both timestamp columns are written by one encoder" timestampsRoundTheSameWay
        , testCase "a record write leaves a fresher discussion alone" recordWriteLeavesDiscussionAlone
        , testCase "a discussion stamp is the one the plan gave, not the row's" stampIsThePlansNotTheRows
        , testCase "pipelines and jobs are written, their objects shared" pipelinesAreWritten
        , testCase "rewriting pipelines replaces rather than duplicates" pipelinesRewriteReplaces
        ]
    , testGroup
        "clear-timestamp"
        [ testCase "a cleared store fetches its discussions again" clearForcesRefetch
        , testCase "the notes themselves are kept" clearKeepsNotes
        , testCase "clearing twice is the same as clearing once" clearIsIdempotent
        ]
    , testGroup
        "schema"
        [ testCase "splitting and splicing are inverse" splitSpliceRoundtrips
        , testCase "an absent field is not invented" splitKeepsAbsence
        , testCase "a store at the old schema loses has_discussion" oldStoreLosesHasDiscussion
        , testCase "--backend is parsed" backendFlagParses
        ]
    , testGroup
        "token file"
        [ testCase "a missing token file is reported, not thrown" missingTokenIsReported
        , testCase "an empty token file is reported" emptyTokenIsReported
        , testCase "a token is read and stripped" tokenIsStripped
        ]
    , testGroup
        "rate limit"
        [ testCase "spaces requests out" rateLimitSpacesRequests
        , testCase "one turn is taken per request" rateLimitCountsRequestsOnce
        ]
    , testGroup
        "anti-bot challenge"
        [ testCase "a challenge is waited out and retried" challengeIsRetried
        , testCase "any other error is not retried" otherErrorsAreNotRetried
        , testCase "a success is returned untouched" successIsNotRetried
        , testCase "an interstitial is recognised from the response" challengeIsRecognised
        , testCase "data and real failures are not mistaken for one" challengeIsNotOverEager
        , testCase "the version check keeps the body it is refusing" versionCheckKeepsBody
        ]
    , testGroup
        "locking"
        [ testCase "a second run is turned away" lockIsExclusive
        , testCase "the lock file names the holder" lockRecordsHolder
        , testCase "the lock is released when the run ends" lockIsReleased
        , testCase "separate stores do not contend" lockIsPerStore
        , testCase "one busy store turns the whole run away" lockIsAllOrNothing
        , testCase "another process is excluded, named, and survives a rewrite" lockExcludesAnotherProcess
        ]
    , testGroup
        "store detection"
        [ testCase "the newest store in a directory is the one found" detectsNewestStore
        , testCase "a database being written to is found by its log" detectsThroughWriteAheadLog
        , testCase "backups and empty directories are not stores" detectsNothingToRead
        ]
    , testGroup "--since" sinceTests
    ]

-- | While one run holds a store, a second one is refused rather than allowed
-- to race it. Two 'withStoreLocks' calls in one process is a fair stand in for
-- two processes: the lock belongs to the open file, not to the process.
lockIsExclusive :: Assertion
lockIsExclusive = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let store = dir </> "gitlab.db"
  outer <- withStoreLocks [store] $ withStoreLocks [store] (pure ())
  case outer of
    Left busy -> assertFailure ("outer lock was refused: " <> show busy)
    Right (Right ()) -> assertFailure "second lock was granted while the first was held"
    Right (Left busy) -> busyStore busy @?= store

-- | The holder writes down who it is and when it started, which is what a run
-- that gets turned away reports. Checked after the lock is released, since the
-- file cannot be read while this process holds it open.
lockRecordsHolder :: Assertion
lockRecordsHolder = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let store = dir </> "gitlab.db"
  us <- fromIntegral <$> getCurrentPid
  began <- getCurrentTime
  taken <- withStoreLocks [store] (pure ())
  ended <- getCurrentTime
  taken @?= Right ()

  -- The file outlives the lock, so this is also what proves a leftover lock
  -- file does not keep the next run out.
  info <- readLockInfo (lockPath store)
  case info of
    Nothing -> assertFailure "lock file did not record its holder"
    Just i -> do
      lockPid i @?= us
      assertBool
        ("recorded " <> show (lockStartedAt i) <> ", outside the window of the run")
        (lockStartedAt i >= began && lockStartedAt i <= ended)

-- | A finished run leaves the store lockable again, so the next run is not
-- locked out by its predecessor.
lockIsReleased :: Assertion
lockIsReleased = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let store = dir </> "gitlab.db"
  first' <- withStoreLocks [store] (pure ())
  first' @?= Right ()
  second <- withStoreLocks [store] (pure ())
  second @?= Right ()

-- | Runs pointed at different files have nothing to fight over.
lockIsPerStore :: Assertion
lockIsPerStore = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let tickets = dir </> "one.db"
      mrs = dir </> "two.db"
  result <- withStoreLocks [tickets] $ withStoreLocks [mrs] (pure ())
  result @?= Right (Right ())

-- | A run wants both its stores. Holding only the merge requests is still
-- enough to turn a full run away, and it is named as the reason.
lockIsAllOrNothing :: Assertion
lockIsAllOrNothing = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let tickets = dir </> "one.db"
      mrs = dir </> "two.db"
  result <- withStoreLocks [mrs] $ withStoreLocks [tickets, mrs] (pure ())
  case result of
    Right (Left busy) -> busyStore busy @?= mrs
    other -> assertFailure ("expected mrs to be busy, got " <> show (fmap (fmap (const ())) other))

-- | The case the lock exists for: a genuinely separate process. The tests
-- above nest two locks in one process, which GHC refuses on its own; only a
-- real second process exercises the file lock the operating system keeps.
--
-- The child also rewrites the store while holding it, which is what a
-- checkpoint does mid-run. Since a store is written by renaming a temporary
-- file over it, a lock taken on the store itself would be left holding the
-- replaced file and let this second run straight in.
lockExcludesAnotherProcess :: Assertion
lockExcludesAnotherProcess = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let store = dir </> "gitlab.db"
      ready = dir </> "ready"
      release = dir </> "release"
  self <- getExecutablePath
  child <- spawnProcess self [holdLockFlag, store, ready, release]
  childPid <- getPid child

  took <- waitForFile ready
  assertBool "the child never reported taking the lock" took

  blocked <- withStoreLocks [store] (pure ())
  case blocked of
    Right () -> assertFailure "locked a store another process was holding"
    Left busy -> do
      busyStore busy @?= store
      case busyHolder busy of
        Nothing -> assertFailure "lock file did not record the holding process"
        Just i -> Just (lockPid i) @?= fmap fromIntegral childPid

  -- Letting the child finish must hand the store back.
  writeFile release ""
  waitForProcess child >>= (@?= ExitSuccess)
  freed <- withStoreLocks [store] (pure ())
  freed @?= Right ()

-- | Argument that makes this executable act as the lock holding child of
-- 'lockExcludesAnotherProcess' rather than run the test suite.
holdLockFlag :: String
holdLockFlag = "--hold-lock"

-- | Take the store lock, rewrite the store, say so, and hold it until told to
-- stop. Exits non-zero if the lock could not be taken, which shows up as a
-- failed assertion on the parent's side.
holdLock :: FilePath -> FilePath -> FilePath -> IO ()
holdLock store ready release = do
  result <- withStoreLocks [store] $ do
    -- What a checkpoint does to the file the lock is meant to cover.
    writeFile (store <> ".tmp") ""
    renameFile (store <> ".tmp") store
    writeFile ready ""
    told <- waitForFile release
    if told then pure ExitSuccess else pure (ExitFailure 3)
  exitWith (either (const (ExitFailure 4)) id result)

-- | Wait for a file to turn up, giving up after ten seconds so a wedged child
-- fails the test rather than hanging it.
waitForFile :: FilePath -> IO Bool
waitForFile path = go (1000 :: Int)
  where
    go 0 = pure False
    go n = do
      there <- doesFileExist path
      if there
        then pure True
        else threadDelay 10000 >> go (n - 1)

sinceTests :: [TestTree]
sinceTests =
  [ testCase "absolute day" $
      parseSince "2026-08-01" @?= Right (SinceTime (UTCTime (fromGregorian 2026 8 1) 0))
  , testCase "ISO 8601 timestamp" $
      parseSince "2026-08-01T12:00:00Z"
        @?= Right (SinceTime (UTCTime (fromGregorian 2026 8 1) (12 * 3600)))
  , testCase "relative units" $ do
      parseSince "2 days" @?= Right (SinceAgo 2 Days)
      parseSince "1 week" @?= Right (SinceAgo 1 Weeks)
      parseSince "6 months" @?= Right (SinceAgo 6 Months)
      parseSince "1 year" @?= Right (SinceAgo 1 Years)
  , testCase "abbreviations, plurals and 'ago' are all accepted" $ do
      parseSince "3d" @?= Right (SinceAgo 3 Days)
      parseSince "1 day" @?= Right (SinceAgo 1 Days)
      parseSince "2 weeks ago" @?= Right (SinceAgo 2 Weeks)
      parseSince "  4 Hours  " @?= Right (SinceAgo 4 Hours)
  , testCase "nonsense is rejected" $ do
      assertBool "empty" (isLeft (parseSince ""))
      assertBool "no amount" (isLeft (parseSince "days"))
      assertBool "unknown unit" (isLeft (parseSince "2 fortnights"))
      assertBool "not a date" (isLeft (parseSince "yesterday"))
  , testCase "relative times resolve against now" $ do
      let now = UTCTime (fromGregorian 2026 8 11) (12 * 3600)
      resolveSince now (SinceAgo 2 Days) @?= UTCTime (fromGregorian 2026 8 9) (12 * 3600)
      resolveSince now (SinceAgo 1 Weeks) @?= UTCTime (fromGregorian 2026 8 4) (12 * 3600)
      resolveSince now (SinceAgo 6 Hours) @?= UTCTime (fromGregorian 2026 8 11) (6 * 3600)
  , testCase "months and years follow the calendar" $ do
      let now = UTCTime (fromGregorian 2026 8 11) 0
      resolveSince now (SinceAgo 6 Months) @?= UTCTime (fromGregorian 2026 2 11) 0
      resolveSince now (SinceAgo 1 Years) @?= UTCTime (fromGregorian 2025 8 11) 0
      -- Going back a month from the 31st clips to the end of the month
      -- rather than overshooting into the one before.
      let endOfMonth = UTCTime (fromGregorian 2026 3 31) 0
      resolveSince endOfMonth (SinceAgo 1 Months) @?= UTCTime (fromGregorian 2026 2 28) 0
  , testCase "an absolute since ignores now" $ do
      let t = UTCTime (fromGregorian 2020 1 1) 0
          now = UTCTime (fromGregorian 2026 8 11) 0
      resolveSince now (SinceTime t) @?= t
  ]
  where
    isLeft = either (const True) (const False)

-- | Five turns at 10/s must take at least the four intervals between them.
rateLimitSpacesRequests :: Assertion
rateLimitSpacesRequests = do
  limiter <- newRateLimiter 10
  start <- getMonotonicTime
  mapM_ (const (waitTurn limiter)) [1 :: Int .. 5]
  elapsed <- subtract start <$> getMonotonicTime
  assertBool
    ("expected at least 0.4s, took " <> show elapsed <> "s")
    (elapsed >= 0.4)

-- | A request must announce itself once, not once per time the manager happens
-- to look at it.
--
-- 'managerModifyRequest', the obvious hook and the one this used to use, runs
-- twice for every request: @responseOpen@ applies it to the request it is
-- given and then again inside the redirect loop. That charged two turns of the
-- rate limiter per request, so a limit of two per second delivered one, and
-- the log claimed twice the traffic we were actually making.
--
-- Nothing is listening on the port, which is the point: the hook runs before
-- the connection is attempted, so a refused connection exercises it exactly as
-- a served one does and the test needs no server.
rateLimitCountsRequestsOnce :: Assertion
rateLimitCountsRequestsOnce = do
  limiter <- newRateLimiter 1000
  announced <- newIORef (0 :: Int)
  manager <- rateLimitedManager limiter (\_ -> modifyIORef' announced (+ 1))
  request <- parseRequest "http://127.0.0.1:9/nothing-is-listening-here"
  attempt <- try (httpLbs request manager) :: IO (Either HttpException (Response BL.ByteString))
  count <- readIORef announced
  assertEqual ("one announcement per request, connection " <> outcome attempt) 1 count
  where
    outcome = either (const "refused") (const "served")

-- | A run decides what to ask GitLab about in SQL and a reader decides with
-- 'needsDiscussion'. The two have to agree: if they drift a run either
-- refetches everything or stops refetching anything, and neither shows up as
-- a failure anywhere else.
planAgreesWithReader :: Assertion
planAgreesWithReader = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  assertBool "the fixture needs more than one issue" (length issues > 1)
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    -- One never fetched, one current, one stale, so all three cases are here.
    storeWriteRecords db issues
    plan <- storeDiscussionPlan db issueProxy
    forM_ (drop 1 plan) $ \(iid, stamp) -> storeWriteDiscussion db issueProxy iid stamp notes
    storeWriteRecords db (take 1 (map bumpIssue (drop 1 issues)))

    plan' <- storeDiscussionPlan db issueProxy
    Right store <- storeLoad db :: IO (Either String (Store Issue))
    assertEqual
      "which records a run would ask GitLab about"
      (Map.keys (Map.filter needsDiscussion store))
      (sort (map fst plan'))
    assertBool "the case is not trivial" (not (null plan') && length plan' < Map.size store)

-- | The record's @updated_at@ is extracted from the JSON aeson wrote, and the
-- discussion stamp is 'encodeTime'; a text comparison between them is only
-- sound while both round a timestamp the same way. Aeson trims the fraction,
-- so the cases that would catch a second encoder are whole seconds and
-- trailing zeros, as GitLab actually sends them.
timestampsRoundTheSameWay :: Assertion
timestampsRoundTheSameWay = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  base <- case issues of
    (i : _) -> pure i
    [] -> assertFailure "fixture is empty"
  let sent =
        [ ("2023-02-23T15:04:45.000Z", "2023-02-23T15:04:45Z")
        , ("2023-02-23T15:04:45.100Z", "2023-02-23T15:04:45.1Z")
        , ("2023-02-23T15:04:45.550Z", "2023-02-23T15:04:45.55Z")
        , ("2023-02-23T15:04:45.123Z", "2023-02-23T15:04:45.123Z")
        , ("2023-02-23T15:04:45.123456Z", "2023-02-23T15:04:45.123456Z")
        ]
  stamps <- forM (map fst sent) $ \text ->
    either (assertFailure . ("cannot parse a GitLab timestamp: " ++)) pure $
      eitherDecode (BL.pack (show text))
  -- Pins the rounding itself, so a change in aeson's printer is noticed here
  -- rather than as every discussion turning stale.
  assertEqual "how aeson writes each" (map snd sent) (map (T.unpack . encodeTime) stamps)

  let variants = zipWith (\iid t -> base {issue_iid = iid, issue_updated_at = Just t}) [1 ..] stamps
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    -- Through the write path a run uses: the stamp is the text the plan
    -- handed out, which is where the two encoders would part company.
    fillStore db issueProxy variants notes
    rows <- sqliteTimestampTexts db
    assertEqual "one row per variant" (length variants) (length rows)
    forM_ rows $ \(_, iid, updated, stamp) ->
      assertEqual ("record " ++ show iid ++ " stamp disagrees with its updated_at") updated stamp
    assertEqual
      "the texts SQLite holds"
      (map (Just . T.pack . snd) sent)
      [updated | (_, _, updated, _) <- rows]

-- | The hole the old design left: a run held the whole store and wrote entries
-- back from it, so a run that had not read the notes could write "no notes"
-- over the notes another writer had just fetched. A write now states one thing
-- — this record, as GitLab has it — and a second writer on the same file is
-- the way to check it, since one handle could have got away with remembering.
recordWriteLeavesDiscussionAlone :: Assertion
recordWriteLeavesDiscussionAlone = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  issue <- firstOf issues
  let path = dir </> "gitlab.db"
      iid = issue_iid issue

  withSqliteStore path $ \db -> fillStore db issueProxy [issue] notes
  before <- withSqliteStore path (entryAt iid) :: IO (Entry Issue)

  -- Another run has the same record come round again and writes it.
  withSqliteStore path $ \db -> storeWriteRecords db [issue]
  rewritten <- withSqliteStore path (entryAt iid) :: IO (Entry Issue)
  assertEqual "a record write changed the discussion" (entryJson before) (entryJson rewritten)

  -- And the other way round: writing a discussion must not put back the
  -- record version the notes were fetched against.
  let bumped = bumpIssue issue
  withSqliteStore path $ \db -> storeWriteRecords db [bumped]
  withSqliteStore path $ \db ->
    storeWriteDiscussion db issueProxy iid (fmap encodeTime (issue_updated_at bumped)) (take 1 notes)
  settled <- withSqliteStore path (entryAt iid) :: IO (Entry Issue)
  assertEqual
    "a discussion write changed the record"
    (toJSON bumped)
    (toJSON (entryRecord settled))
  assertEqual
    "the notes it wrote"
    (Just (map note_id (take 1 notes)))
    (fmap (map note_id) (entryNotes settled))

-- | The stamp stored with a discussion is the record version it was planned
-- against, never the version the row happens to hold when it is written. A
-- record that moved while the notes were in flight has to come back as stale:
-- claiming the notes cover an edit they were fetched before would hide that
-- edit's discussion for good, and one redundant refetch is the cheap way to be
-- wrong.
stampIsThePlansNotTheRows :: Assertion
stampIsThePlansNotTheRows = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  issue <- firstOf issues
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    storeWriteRecords db [issue]
    plan <- storeDiscussionPlan db issueProxy
    (iid, stamp) <- case plan of
      (p : _) -> pure p
      [] -> assertFailure "a record with no discussion was not planned for"

    -- The record moves between the plan and the write.
    storeWriteRecords db [bumpIssue issue]
    storeWriteDiscussion db issueProxy iid stamp notes

    plan' <- storeDiscussionPlan db issueProxy
    assertEqual "the record that moved is stale again" [iid] (map fst plan')
    entry <- entryAt iid db :: IO (Entry Issue)
    assertEqual
      "the notes were written all the same"
      (Just (map note_id notes))
      (fmap (map note_id) (entryNotes entry))

-- | A store written by the version before @has_discussion@ was dropped is
-- migrated when it is opened, rather than refused or read with a column that
-- is no longer written.
oldStoreLosesHasDiscussion :: Assertion
oldStoreLosesHasDiscussion = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  issue <- firstOf issues
  let path = dir </> "gitlab.db"
      stamp = fmap encodeTime (issue_updated_at issue)

  -- A store as the previous version left it: the records table with the
  -- column, and the meta rows saying patch 1 has been applied.
  raw <- SQL.open path
  SQL.execute_ raw oldRecordsTable
  SQL.execute_ raw "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)"
  SQL.execute_ raw "INSERT INTO meta VALUES ('schema_version', '1'), ('schema_patch_version', '1')"
  SQL.execute
    raw
    "INSERT INTO records (kind, iid, discussion_updated_at, has_discussion, rest, lifted) \
    \ VALUES ('ticket', ?, ?, 1, ?, '[]')"
    (issue_iid issue, stamp, decodeUtf8 (BL.toStrict (encode (toJSON issue))))
  SQL.close raw

  withSqliteStore path $ \db -> do
    Right store <- storeLoad db :: IO (Either String (Store Issue))
    entry <- entryAt (issue_iid issue) db :: IO (Entry Issue)
    assertEqual "the store still holds what it held" 1 (Map.size store)
    assertEqual "the record survived the patch" (toJSON issue) (toJSON (entryRecord entry))
    assertEqual
      "and so did its discussion stamp"
      (issue_updated_at issue)
      (entryDiscussionFor entry)
    plan <- storeDiscussionPlan db issueProxy
    assertEqual "a stamped record is not asked about again" [] (map fst plan)

  columns <- do
    raw' <- SQL.open path
    cols <- SQL.query_ raw' "SELECT name FROM pragma_table_info('records')" :: IO [SQL.Only T.Text]
    SQL.close raw'
    pure [c | SQL.Only c <- cols]
  assertBool ("has_discussion is still there: " <> show columns) ("has_discussion" `notElem` columns)

-- | The @records@ table as the version before the patch created it: the same
-- statement with @has_discussion@ still in it. The generated columns are kept
-- because the base schema indexes some of them, and running the base
-- statements over this table is part of what is being tested.
oldRecordsTable :: SQL.Query
oldRecordsTable =
  "CREATE TABLE records (\
  \  kind                  TEXT NOT NULL,\
  \  iid                   INTEGER NOT NULL,\
  \  milestone_row         INTEGER,\
  \  discussion_updated_at TEXT,\
  \  has_discussion        INTEGER NOT NULL,\
  \  rest                  TEXT NOT NULL,\
  \  lifted                TEXT NOT NULL,\
  \  id               INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.id')) VIRTUAL,\
  \  project_id       INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.project_id')) VIRTUAL,\
  \  title            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.title')) VIRTUAL,\
  \  description      TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.description')) VIRTUAL,\
  \  state            TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.state')) VIRTUAL,\
  \  created_at       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.created_at')) VIRTUAL,\
  \  updated_at       TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.updated_at')) VIRTUAL,\
  \  closed_at        TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.closed_at')) VIRTUAL,\
  \  web_url          TEXT    GENERATED ALWAYS AS (json_extract(rest, '$.web_url')) VIRTUAL,\
  \  user_notes_count INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.user_notes_count')) VIRTUAL,\
  \  upvotes          INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.upvotes')) VIRTUAL,\
  \  downvotes        INTEGER GENERATED ALWAYS AS (json_extract(rest, '$.downvotes')) VIRTUAL,\
  \  PRIMARY KEY (kind, iid))"

-- | An anti-bot challenge is transient, so it is waited out rather than
-- failed on. The waits are passed in so the test does not have to sit through
-- the real ladder.
challengeIsRetried :: Assertion
challengeIsRetried = do
  attempts <- newIORef (0 :: Int)
  let act = do
        n <- liftIO $ atomicModifyIORef' attempts (\n -> (n + 1, n + 1))
        pure $
          if n < 3
            then Left (GitLabChallengeError "anubis") :: Either GitLabError T.Text
            else Right "the data"
  result <- runQuietly (waitOutChallenge [0, 0, 0] act)
  assertEqual "the retry did not return the data" (Just "the data") (succeeded result)
  readIORef attempts >>= assertEqual "gave up too early or retried too often" 3

-- | Everything else fails on the first try. Waiting out a bad token would turn
-- a mistyped file into half an hour of silence.
otherErrorsAreNotRetried :: Assertion
otherErrorsAreNotRetried = do
  attempts <- newIORef (0 :: Int)
  let act = do
        liftIO $ modifyIORef' attempts (+ 1)
        pure (Left (GitLabError "access token not accepted.") :: Either GitLabError T.Text)
  result <- runQuietly (waitOutChallenge [0, 0, 0] act)
  case result of
    Left (GitLabError message) -> message @?= "access token not accepted."
    other -> assertFailure ("expected the error back unchanged, got " <> show other)
  readIORef attempts >>= assertEqual "an ordinary error was retried" 1

successIsNotRetried :: Assertion
successIsNotRetried = do
  attempts <- newIORef (0 :: Int)
  let act = do
        liftIO $ modifyIORef' attempts (+ 1)
        pure (Right "fine" :: Either GitLabError T.Text)
  result <- runQuietly (waitOutChallenge challengeWaits act)
  assertEqual "a success came back changed" (Just "fine") (succeeded result)
  readIORef attempts >>= assertEqual "a success was repeated" 1

-- | 'GitLabError' has no 'Eq', so results are compared on the success side.
succeeded :: Either GitLabError a -> Maybe a
succeeded = either (const Nothing) Just

-- | Run a 'LogT' action without putting its logging on the test output. The
-- challenge path logs at attention, which is exactly what a passing test
-- should not print.
runQuietly :: LogT IO a -> IO a
runQuietly act = do
  logger <- mkLogger "test" (\_ -> pure ())
  withLogger logger $ \sink -> runLogT "test" sink LogTrace act

-- | An entry with notes attached survives the trip through the store, and
-- comes back no longer needing a discussion.
discussionRoundtrips :: Assertion
discussionRoundtrips = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  assertBool "fixture has notes" (not (null notes))

  let path = dir </> "gitlab.db"
  withSqliteStore path $ \db -> fillStore db issueProxy issues notes

  withSqliteStore path $ \db -> do
    Right store <- storeLoad db :: IO (Either String (Store Issue))
    assertEqual "entries" (sort (nub (map issue_iid issues))) (Map.keys store)
    plan <- storeDiscussionPlan db issueProxy
    assertEqual "nothing still wants its discussion" [] (map fst plan)
    assertBool "and the reader agrees" (not (any needsDiscussion (Map.elems store)))
    assertEqual
      "notes came back"
      (replicate (Map.size store) (Just (map note_id notes)))
      (map (fmap (map note_id) . entryNotes) (Map.elems store))

-- | Re-fetching a record must not throw away the discussion we already have.
recordWriteKeepsDiscussion :: Assertion
recordWriteKeepsDiscussion = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    fillStore db issueProxy issues notes
    Right before <- storeLoad db :: IO (Either String (Store Issue))
    storeWriteRecords db issues
    Right rewritten <- storeLoad db :: IO (Either String (Store Issue))
    assertEqual "same entries" (Map.keys before) (Map.keys rewritten)
    assertEqual
      "discussions survived"
      (map entryJson (Map.elems before))
      (map entryJson (Map.elems rewritten))
    plan <- storeDiscussionPlan db issueProxy
    assertEqual "and are still current" [] (map fst plan)

-- | If the record changed after we fetched its discussion, we have to look
-- again; that is what lets an interrupted notes run resume.
changedRecordIsStale :: Assertion
changedRecordIsStale = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  issue <- firstOf issues
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    fillStore db issueProxy [issue] notes
    plan <- storeDiscussionPlan db issueProxy
    assertEqual "current right after fetching" [] (map fst plan)

    storeWriteRecords db [bumpIssue issue]
    plan' <- storeDiscussionPlan db issueProxy
    assertEqual "stale once the record moves" [issue_iid issue] (map fst plan')
    entry <- entryAt (issue_iid issue) db :: IO (Entry Issue)
    assertBool "and the reader agrees" (needsDiscussion entry)

-- | The whole point of storing @discussion_updated_at@: a run over a project
-- that has not moved must not spend a single request on notes it already has.
--
-- This is a full cycle rather than an in-memory check, because the store on
-- disk is what a second run actually sees, and a timestamp that did not
-- survive being written would make every run re-fetch everything.
secondRunAsksForNothing :: Assertion
secondRunAsksForNothing = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  let path = dir </> "gitlab.db"

  -- First run: fetch the records, fetch their notes, write.
  withSqliteStore path $ \db -> fillStore db issueProxy issues notes

  -- Second run: let GitLab hand us the same records over again, which it does
  -- for anything modified within a second of our newest.
  withSqliteStore path $ \db -> do
    current <- alreadyCurrent db issues
    assertEqual "every re-fetched record was one we already had" (length issues) current
    storeWriteRecords db issues
    plan <- storeDiscussionPlan db issueProxy
    assertEqual "nothing is requested a second time" [] (map fst plan)
    held <- storeRecordCount db issueProxy
    assertEqual "no entries appeared or vanished" (length (nub (map issue_iid issues))) held

-- | And the converse: a record that really did change is the only one asked
-- about again, so a run costs requests in proportion to what moved.
onlyChangedIsRefetched :: Assertion
onlyChangedIsRefetched = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  issue <- firstOf issues
  let path = dir </> "gitlab.db"
  withSqliteStore path $ \db -> fillStore db issueProxy issues notes

  withSqliteStore path $ \db -> do
    let touched = bumpIssue issue
    assertEqual "it is not counted as current" 0 =<< alreadyCurrent db [touched]
    storeWriteRecords db [touched]
    plan <- storeDiscussionPlan db issueProxy
    assertEqual "only the record that moved" [issue_iid issue] (map fst plan)

-- | What a run reports as fetched for nothing.
countsUnchangedRecords :: Assertion
countsUnchangedRecords = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    assertEqual "none against an empty store" 0 =<< alreadyCurrent db issues
    storeWriteRecords db issues
    assertEqual "all of them" (length issues) =<< alreadyCurrent db issues

changedIsNotCurrent :: Assertion
changedIsNotCurrent = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    storeWriteRecords db issues
    case issues of
      [] -> assertFailure "fixture is empty"
      (issue : rest) ->
        assertEqual "all but the changed one" (length rest)
          =<< alreadyCurrent db (bumpIssue issue : rest)

-- | The claim the SQLite backend has to earn: what comes out is what went in.
--
-- Comparing the encoded 'Entry' rather than the record alone covers the
-- discussion and the timestamp the staleness check depends on, all three of
-- which travel through separate tables and have to arrive together.
sqliteRoundtrips :: forall a. Record a => Proxy a -> FilePath -> Assertion
sqliteRoundtrips proxy path = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  records <- decodeFixture path :: IO [a]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  assertBool (path <> " has no records") (not (null records))

  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    storeWriteRecords db records
    -- Half the entries get a discussion and half do not, so that both the
    -- fetched and the never-fetched case are exercised.
    plan <- storeDiscussionPlan db proxy
    let (fetched, untouched) = everyOther plan
    forM_ fetched $ \(iid, stamp) -> storeWriteDiscussion db proxy iid stamp notes

    reread <- storeLoad db :: IO (Either String (Store a))
    case reread of
      Left err -> assertFailure ("reading the database back failed: " <> err)
      Right store -> do
        assertEqual "keys" (sort (map recordKey records)) (Map.keys store)
        assertEqual
          "the records themselves"
          (map toJSON (sortOn recordKey records))
          (map (toJSON . entryRecord) (Map.elems store))
        forM_ fetched $ \(iid, _) -> do
          let e = store Map.! iid
          assertEqual
            ("the notes of " <> show iid)
            (Just (map note_id notes))
            (fmap (map note_id) (entryNotes e))
          assertBool ("still stale: " <> show iid) (not (needsDiscussion e))
        forM_ untouched $ \(iid, _) -> do
          let e = store Map.! iid
          assertEqual ("notes appeared for " <> show iid) Nothing (fmap (map note_id) (entryNotes e))
          assertBool ("silently current: " <> show iid) (needsDiscussion e)
  where
    everyOther xs = ([x | (n, x) <- indexed, even n], [x | (n, x) <- indexed, odd n])
      where
        indexed = zip [0 :: Int ..] xs

sqliteStartsEmpty :: Assertion
sqliteStartsEmpty = withSystemTempDirectory "fetch-gitlab-test" $ \dir ->
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    loaded <- storeLoad db :: IO (Either String (Store Issue))
    case loaded of
      Left err -> assertFailure ("a fresh database should be empty, got: " <> err)
      Right store -> assertEqual "empty" 0 (Map.size store)

-- | The reason for the backend at all: a write must not rewrite the whole
-- store, and must not lose the part it did not name.
sqliteWritesOnlyWhatItNames :: Assertion
sqliteWritesOnlyWhatItNames = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  case map issue_iid issues of
    [] -> assertFailure "fixture is empty"
    (target : others) -> withSqliteStore (dir </> "gitlab.db") $ \db -> do
      storeWriteRecords db issues
      stamps <- Map.fromList <$> storeDiscussionPlan db issueProxy

      -- Give one entry a discussion, and check nothing else moved.
      storeWriteDiscussion db issueProxy target (Map.findWithDefault Nothing target stamps) notes
      Right reread <- storeLoad db :: IO (Either String (Store Issue))
      assertEqual "nothing appeared or vanished" (sort (nub (map issue_iid issues))) (Map.keys reread)
      assertBool
        "the entry we wrote did not gain its discussion"
        (not (needsDiscussion (reread Map.! target)))
      assertBool
        "an entry we did not write was changed"
        (all (\k -> needsDiscussion (reread Map.! k)) others)

      -- A record write of the others must leave the one with notes alone, and
      -- writing nothing must leave everything alone.
      storeWriteRecords db [i | i <- issues, issue_iid i /= target]
      storeWriteRecords db ([] :: [Issue])
      Right settled <- storeLoad db :: IO (Either String (Store Issue))
      assertEqual
        "a write of other records changed the store"
        (map entryJson (Map.elems reread))
        (map entryJson (Map.elems settled))

sqliteSurvivesReopen :: Assertion
sqliteSurvivesReopen = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  let path = dir </> "gitlab.db"
  written <- withSqliteStore path $ \db -> do
    fillStore db issueProxy issues notes
    storeLoad db :: IO (Either String (Store Issue))
  withSqliteStore path $ \db -> do
    Right reread <- storeLoad db :: IO (Either String (Store Issue))
    Right store <- pure written
    assertEqual
      "what a later run reads"
      (map entryJson (Map.elems store))
      (map entryJson (Map.elems reread))

-- | Sharing is the point of the schema, so it is worth checking it happens
-- rather than assuming it: the same author on every note must be one row.
sqliteSharesUsers :: Assertion
sqliteSharesUsers = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  let distinct = length (nub (map (encode . toJSON . note_author) notes))
      references = length issues * length notes
  assertBool "fixture does not repeat any user" (references > distinct)
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    fillStore db issueProxy issues notes
    counts <- sqliteTableCounts db
    let stored = maybe 0 id (lookup "users" counts)
        refs = maybe 0 id (lookup "note_users" counts)
    assertBool
      ( "expected far fewer user rows than references, got "
          <> show stored
          <> " rows for "
          <> show refs
          <> " note references"
      )
      (stored < refs)

-- | What one --pipelines fetch of a two pipeline merge request hands the
-- store: the same commit and user on every job, one runner seen in two
-- states.
pipelineFixture :: [(Value, [Value])]
pipelineFixture =
  [ (pipelineJson 101, [jobJson 9001 "success" runnerIdle, jobJson 9002 "failed" runnerIdle])
  , (pipelineJson 102, [jobJson 9003 "failed" runnerBusy])
  ]
  where
    runnerIdle = runnerJson "idle"
    runnerBusy = runnerJson "busy"

    pipelineJson :: Int -> Value
    pipelineJson pid =
      object
        [ "id" .= pid
        , "iid" .= (pid + 500)
        , "status" .= ("failed" :: T.Text)
        , "sha" .= sha
        , "created_at" .= ("2026-07-18T09:20:50.122Z" :: T.Text)
        ]

    jobJson :: Int -> T.Text -> Value -> Value
    jobJson jid status runner =
      object
        [ "id" .= jid
        , "status" .= status
        , "stage" .= ("full-build" :: T.Text)
        , "created_at" .= ("2026-07-18T09:20:50.200Z" :: T.Text)
        , "started_at" .= ("2026-07-18T09:21:00.000Z" :: T.Text)
        , "duration" .= (3805.2 :: Double)
        , "queued_duration" .= (9.7 :: Double)
        , "name" .= ("x86_64-linux-validate" :: T.Text)
        , "user" .= object ["id" .= (7 :: Int), "username" .= ("andreask" :: T.Text)]
        , "commit" .= object ["id" .= sha, "author_name" .= ("A. Klebinger" :: T.Text), "author_email" .= ("a@example.org" :: T.Text)]
        , "runner" .= runner
        , "pipeline" .= object ["id" .= (101 :: Int), "sha" .= sha]
        , "tag_list" .= (["x86_64-linux"] :: [T.Text])
        ]

    runnerJson :: T.Text -> Value
    runnerJson state = object ["id" .= (792 :: Int), "description" .= ("maki" :: T.Text), "status" .= state]

    sha = "fd9855fa6e96f7ab472d754c411d5353c9ab38f2" :: T.Text

-- | One write of the fixture: every pipeline and job lands, the objects a job
-- repeats are shared rather than copied — one commit and one user across all
-- three jobs — and a runner seen in two states is kept as two rows.
pipelinesAreWritten :: Assertion
pipelinesAreWritten = withSystemTempDirectory "fetch-gitlab-test" $ \dir ->
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    storeWritePipelines db "mr" 16366 pipelineFixture
    counts <- sqliteTableCounts db
    let count t = maybe 0 id (lookup t counts)
    assertEqual "pipelines" 2 (count "pipelines")
    assertEqual "jobs" 3 (count "jobs")
    assertEqual "commits" 1 (count "commits")
    assertEqual "users" 1 (count "users")
    assertEqual "runner states" 2 (count "runners")

-- | Fetching the same merge request again replaces what is there. The id
-- columns are what stop a second write doubling every table.
pipelinesRewriteReplaces :: Assertion
pipelinesRewriteReplaces = withSystemTempDirectory "fetch-gitlab-test" $ \dir ->
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    storeWritePipelines db "mr" 16366 pipelineFixture
    before <- sqliteTableCounts db
    storeWritePipelines db "mr" 16366 pipelineFixture
    after <- sqliteTableCounts db
    assertEqual "a rewrite changes no table" before after

-- | The point of the command: a store that thinks its discussions are current
-- has to stop thinking so.
clearForcesRefetch :: Assertion
clearForcesRefetch = withClearedStore $ \before cleared -> do
  assertBool
    "the fixture was already stale, so this proves nothing"
    (not (any needsDiscussion (Map.elems before)))
  assertBool
    "clearing left entries still claiming to be current"
    (all needsDiscussion (Map.elems cleared))

-- | Only the claim that they are current is dropped. Throwing the notes away
-- would leave the store useless until the refetch finished.
clearKeepsNotes :: Assertion
clearKeepsNotes = withClearedStore $ \before cleared -> do
  assertEqual "entries" (Map.keys before) (Map.keys cleared)
  assertEqual
    "the notes changed"
    (map (fmap (map note_id) . entryNotes) (Map.elems before))
    (map (fmap (map note_id) . entryNotes) (Map.elems cleared))
  assertEqual
    "the records changed"
    (map (toJSON . entryRecord) (Map.elems before))
    (map (toJSON . entryRecord) (Map.elems cleared))

-- | Running it twice must not do anything the second time, so it is safe to
-- repeat when a run in between was interrupted.
clearIsIdempotent :: Assertion
clearIsIdempotent = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    fillStore db issueProxy issues notes
    runNoLog (clearTimestamps db)
    Right once <- storeLoad db :: IO (Either String (Store Issue))
    runNoLog (clearTimestamps db)
    Right twice <- storeLoad db :: IO (Either String (Store Issue))
    assertEqual
      "the second clearing changed something"
      (map entryJson (Map.elems once))
      (map entryJson (Map.elems twice))

-- | A store with current discussions, before and after clearing it.
withClearedStore :: (Store Issue -> Store Issue -> Assertion) -> Assertion
withClearedStore check = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    fillStore db issueProxy issues notes
    Right before <- storeLoad db :: IO (Either String (Store Issue))
    runNoLog (clearTimestamps db)
    Right cleared <- storeLoad db :: IO (Either String (Store Issue))
    check before cleared

-- | Conversions log, and the tests do not care what they say.
runNoLog :: LogT IO a -> IO a
runNoLog act = withStdOutLogger $ \logger -> runLogT "test" logger LogAttention act

-- | 'splitObject' takes shared objects out and 'spliceObject' puts them back;
-- if that is not exact then nothing else about the backend matters.
splitSpliceRoundtrips :: Assertion
splitSpliceRoundtrips = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  mrs <- decodeFixture "test/data/mrs.jsonl" :: IO [MergeRequest]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  mapM_ (check recordSpec . toJSON) issues
  mapM_ (check recordSpec . toJSON) mrs
  mapM_ (check noteSpec . toJSON) notes
  where
    check spec v =
      let (rest, lifted) = splitObject spec v
       in assertEqual "splicing did not restore the value" v (spliceObject spec lifted rest)

-- | A field that was not there must not come back, and an empty list must not
-- become an absent one: both decide whether a discussion is refetched.
splitKeepsAbsence :: Assertion
splitKeepsAbsence = do
  let withEmpty = object ["iid" .= (1 :: Int), "assignees" .= ([] :: [Value]), "labels" .= ([] :: [Value])]
      without = object ["iid" .= (1 :: Int)]
  mapM_ (check recordSpec) [withEmpty, without]
  assertBool
    "an empty list should still be lifted"
    (liftedKeys (snd (splitObject recordSpec withEmpty)) /= [])
  assertEqual
    "an absent field should lift nothing"
    []
    (liftedKeys (snd (splitObject recordSpec without)))
  where
    check spec v =
      let (rest, lifted) = splitObject spec v
       in assertEqual "splicing changed the value" v (spliceObject spec lifted rest)

backendFlagParses :: Assertion
backendFlagParses = do
  parseBackend "sqlite" @?= Right SqliteBackend
  parseBackend "sqlite3" @?= Right SqliteBackend
  assertBool "nonsense is rejected" (either (const True) (const False) (parseBackend "postgres"))

-- | The library hands a challenge back as an ordinary failure on the paths
-- that do not raise for themselves, so a run has to recognise one from the
-- response: HTTP 200 with an HTML body that says it is checking you are not a
-- bot.
challengeIsRecognised :: Assertion
challengeIsRecognised = do
  case challengeDetail status200 anubisPage of
    Nothing -> assertFailure "an Anubis interstitial was not recognised"
    Just detail -> do
      assertBool ("detail names the status: " <> show detail) ("200" `isInfixOf` T.unpack detail)
      assertBool
        ("detail quotes the body: " <> show detail)
        ("anubis" `isInfixOf` T.unpack detail)
  -- 226 is the top of what the library counts as success, and the marker can
  -- sit past whatever <head> precedes it.
  assertBool "a later marker still counts" (isJust (challengeDetail (mkStatus 226 "IM Used") anubisPage))

-- | The ladder costs half an hour, so nothing else may trigger it. A real
-- failure has to fail on the first try, and data has to be data.
challengeIsNotOverEager :: Assertion
challengeIsNotOverEager = do
  assertEqual "JSON is not a challenge" Nothing (challengeDetail status200 "[{\"iid\": 1}]")
  assertEqual
    "an ordinary HTML page is not a challenge"
    Nothing
    (challengeDetail status200 "<!doctype html><title>Hello</title>")
  -- The case that matters most: the same page under an error status is a
  -- genuine failure, and waiting it out would turn a wrong token or a broken
  -- proxy into half an hour of silence.
  assertEqual
    "an interstitial under 503 is a failure, not a challenge"
    Nothing
    (challengeDetail status503 anubisPage)
  assertEqual "an empty body is not a challenge" Nothing (challengeDetail status200 "")

-- | The @/version@ token check reports a status it has no branch for through
-- the library's 'unexpectedStatus'. The status line alone points at nothing;
-- the body is what says whether it was the server, a proxy or an
-- interstitial, so the message has to carry it.
versionCheckKeepsBody :: Assertion
versionCheckKeepsBody = do
  case unexpectedStatus "/version" status503 anubisPage of
    GitLabError message -> do
      assertBool ("message names the path: " <> show message) ("/version" `isInfixOf` T.unpack message)
      assertBool ("message names the status: " <> show message) ("503" `isInfixOf` T.unpack message)
      assertBool ("message quotes the body: " <> show message) ("anubis" `isInfixOf` T.unpack message)
    err -> assertFailure ("an interstitial under 503 must stay an error, got " <> show err)
  -- The same page as a success is the real thing. Unreachable from the token
  -- check today, since a success never gets this far, but the classifier must
  -- agree with 'challengeDetail' about where the line is either way.
  case unexpectedStatus "/version" status200 anubisPage of
    GitLabChallengeError _ -> pure ()
    err -> assertFailure ("an interstitial served as success is a challenge, got " <> show err)

-- | Shaped after what gitlab.haskell.org actually served during a long run.
anubisPage :: BL.ByteString
anubisPage =
  BL.pack $
    "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
      <> "<title>Making sure you're not a bot!</title>\n</head>\n<body>\n"
      <> "<div id=\"anubis_challenge\">Checking your browser...</div>\n</body>\n</html>\n"

-- | A mistyped @--token@ path has to come back as something we can log, not as
-- an exception out of the middle of a run.
missingTokenIsReported :: Assertion
missingTokenIsReported = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let path = dir </> "no-such-token"
  result <- readToken path
  case result of
    Right t -> assertFailure ("expected a failure, read " <> show t)
    Left err -> do
      assertBool ("error names the file: " <> show err) (path `isInfixOf` T.unpack err)
      assertBool ("error says what is wrong: " <> show err) ("no such file" `isInfixOf` T.unpack err)

-- | An empty file is caught here rather than surfacing as an unauthorised
-- response after the first request.
emptyTokenIsReported :: Assertion
emptyTokenIsReported = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let path = dir </> "token"
  writeFile path "\n  \n"
  result <- readToken path
  case result of
    Right t -> assertFailure ("expected a failure, read " <> show t)
    Left err -> assertBool ("error mentions emptiness: " <> show err) ("empty" `isInfixOf` T.unpack err)

-- | Tokens are pasted into files with a trailing newline; that must not become
-- part of the credential.
tokenIsStripped :: Assertion
tokenIsStripped = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let path = dir </> "token"
  writeFile path "  glpat-secret\n"
  readToken path >>= (@?= Right "glpat-secret")

-- | Writing a record the store already has replaces it rather than adding a
-- second row, which is what makes a page that repeats its anchor harmless.
recordWriteReplaces :: Assertion
recordWriteReplaces = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    storeWriteRecords db (take 1 issues)
    storeWriteRecords db issues
    Right store <- storeLoad db :: IO (Either String (Store Issue))
    assertEqual "one entry per iid" (sort (nub (map issue_iid issues))) (Map.keys store)
    assertEqual "and the count agrees" (Map.size store) =<< storeRecordCount db issueProxy

-- | Where an incremental run starts is the newest record the store holds, and
-- it is the store that says so rather than anything a run remembers.
latestUpdateIsNewest :: Assertion
latestUpdateIsNewest = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  let expected = maximum [t | Just t <- map recordUpdatedAt issues] :: UTCTime
  withSqliteStore (dir </> "gitlab.db") $ \db -> do
    assertEqual "an empty store starts from nothing" Nothing =<< storeLatestUpdate db issueProxy
    storeWriteRecords db issues
    assertEqual "newest timestamp" (Just expected) =<< storeLatestUpdate db issueProxy

-- | A directory can hold more than one store: a run pointed at a second
-- database, or a copy taken before some experiment. The one being written to
-- is the one to read, and that is the newest.
detectsNewestStore :: Assertion
detectsNewestStore = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let db = dir </> "gitlab.db"
      other = dir </> "other.db"
      at = UTCTime (fromGregorian 2026 1 1) 0

  -- Only the names and the timestamps matter here; nothing is opened.
  forM_ [db, other] (`writeFile` "")
  setModificationTime db at
  setModificationTime other (addUTCTime 60 at)
  detected <- detectSpec dir
  assertEqual "the newer of the two" (Just (SqliteSpec other)) detected

  setModificationTime db (addUTCTime 120 at)
  detected' <- detectSpec dir
  assertEqual "the other one, once it is the newer" (Just (SqliteSpec db)) detected'

-- | The case that makes a naive timestamp comparison wrong: a run checkpoints
-- into the write ahead log and only folds it into the database when it closes,
-- so mid-fetch the database file itself can be the oldest thing in the
-- directory.
detectsThroughWriteAheadLog :: Assertion
detectsThroughWriteAheadLog = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let db = dir </> "gitlab.db"
      other = dir </> "other.db"
      at = UTCTime (fromGregorian 2026 1 1) 0

  forM_ [db, other, db <> "-wal"] (`writeFile` "")
  setModificationTime db at
  setModificationTime other (addUTCTime 60 at)
  setModificationTime (db <> "-wal") (addUTCTime 120 at)
  detected <- detectSpec dir
  assertEqual "the store being written to" (Just (SqliteSpec db)) detected

-- | Nothing is a store until it is named like one. A backup copy beside the
-- database is the reason: reading one of those would quietly show a reader a
-- snapshot of last week.
detectsNothingToRead :: Assertion
detectsNothingToRead = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  empty' <- detectSpec dir
  assertEqual "an empty directory" Nothing empty'

  missing <- detectSpec (dir </> "not-there")
  assertEqual "a directory that does not exist" Nothing missing

  forM_ ["gitlab.db.bak-20260816", "gitlab.db.lock", "notes.txt"] $ \name ->
    writeFile (dir </> name) ""
  backups <- detectSpec dir
  assertEqual "backups and lock files" Nothing backups

decodeFixture :: FromJSON a => FilePath -> IO [a]
decodeFixture path = do
  contents <- BL.readFile path
  let ls = filter (not . BL.null) (BL.lines contents)
  traverse decodeOrFail ls
  where
    decodeOrFail line = either (assertFailure . (("decoding " <> path <> ": ") <>)) pure (eitherDecode line)

-- | An entry as a value, for comparing one store against another: the record,
-- the notes hanging off it, and the record version those notes were fetched
-- for. 'Entry' has no 'Eq' of its own, and this says what "the same entry"
-- means for these tests without a store format having to say it.
entryJson :: Record a => Entry a -> Value
entryJson e =
  object
    [ "record" .= toJSON (entryRecord e)
    , "discussion" .= toJSON (entryNotes e)
    , "discussion_updated_at" .= toJSON (entryDiscussionFor e)
    ]

issueProxy :: Proxy Issue
issueProxy = Proxy

-- | What a first run leaves behind: the records written, then the discussion
-- of everything the store asked for, stamped as the plan said.
fillStore :: Record a => SqliteStore -> Proxy a -> [a] -> [Note] -> IO ()
fillStore db proxy records notes = do
  storeWriteRecords db records
  plan <- storeDiscussionPlan db proxy
  forM_ plan $ \(iid, stamp) -> storeWriteDiscussion db proxy iid stamp notes

-- | One entry, or a failed assertion if the store does not hold it.
entryAt :: Record a => Int -> SqliteStore -> IO (Entry a)
entryAt iid db = do
  found <- storeLookup db iid
  case found of
    Left err -> assertFailure ("reading the store failed: " <> err)
    Right Nothing -> assertFailure ("the store does not hold " <> show iid)
    Right (Just e) -> pure e

-- | How many of these records the store already holds at exactly this
-- version, which is what 'FetchGitLab.Fetch.fetchRecords' reports as fetched
-- for nothing.
alreadyCurrent :: Record a => SqliteStore -> [a] -> IO Int
alreadyCurrent db records = do
  stored <- storeRecordVersions db (proxyOf records) (map recordKey records)
  pure (length [r | r <- records, Map.lookup (recordKey r) stored == Just (recordUpdatedAt r)])
  where
    proxyOf :: [a] -> Proxy a
    proxyOf _ = Proxy

-- | A record whose @updated_at@ moved, which is what makes its discussion
-- stale.
bumpIssue :: Issue -> Issue
bumpIssue i = i {issue_updated_at = fmap (addUTCTime 60) (issue_updated_at i)}

firstOf :: [a] -> IO a
firstOf (x : _) = pure x
firstOf [] = assertFailure "fixture is empty"
