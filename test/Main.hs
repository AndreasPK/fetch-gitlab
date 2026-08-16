{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for the JSON lines store.
module Main (main) where

import Control.Concurrent (threadDelay)
import Data.Aeson (FromJSON, ToJSON, Value (..), eitherDecode, toJSON)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.List (isInfixOf)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, getCurrentTime)
import GHC.Clock (getMonotonicTime)
import System.Directory (doesFileExist)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.Process (getCurrentPid, getPid, spawnProcess, waitForProcess)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty
import Test.Tasty.HUnit

import GitLab.Types (Issue (..), MergeRequest, Note (..))

import FetchGitLab.Fetch (readToken)
import FetchGitLab.Lock
  ( LockBusy (..)
  , LockInfo (..)
  , lockPath
  , readLockInfo
  , withStoreLocks
  )
import FetchGitLab.RateLimit (newRateLimiter, waitTurn)
import FetchGitLab.Since (Since (..), Unit (..), parseSince, resolveSince)
import FetchGitLab.Store
  ( Entry (..)
  , Record (..)
  , Store
  , alreadyCurrent
  , latestUpdate
  , mergeRecords
  , needsDiscussion
  , newEntry
  , readStore
  , setDiscussion
  , writeStore
  )

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
        "JSON lines roundtrip"
        [ testCase "issues" $ roundtripFile (Proxy :: Proxy Issue) "test/data/issues.jsonl"
        , testCase "merge requests" $ roundtripFile (Proxy :: Proxy MergeRequest) "test/data/mrs.jsonl"
        ]
    , testGroup
        "store"
        [ testCase "missing file is an empty store" missingFileIsEmpty
        , testCase "reading a corrupt file fails" corruptFileFails
        , testCase "merging replaces records with the same iid" mergeReplaces
        , testCase "latestUpdate finds the newest timestamp" latestUpdateIsNewest
        ]
    , testGroup
        "discussions"
        [ testCase "an entry with a discussion roundtrips" discussionRoundtrips
        , testCase "merging keeps the discussion we already have" mergeKeepsDiscussion
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
        "token file"
        [ testCase "a missing token file is reported, not thrown" missingTokenIsReported
        , testCase "an empty token file is reported" emptyTokenIsReported
        , testCase "a token is read and stripped" tokenIsStripped
        ]
    , testGroup
        "rate limit"
        [ testCase "spaces requests out" rateLimitSpacesRequests
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
    , testGroup "--since" sinceTests
    ]

-- | While one run holds a store, a second one is refused rather than allowed
-- to race it. Two 'withStoreLocks' calls in one process is a fair stand in for
-- two processes: the lock belongs to the open file, not to the process.
lockIsExclusive :: Assertion
lockIsExclusive = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let store = dir </> "tickets.jsonl"
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
  let store = dir </> "tickets.jsonl"
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
  let store = dir </> "tickets.jsonl"
  first' <- withStoreLocks [store] (pure ())
  first' @?= Right ()
  second <- withStoreLocks [store] (pure ())
  second @?= Right ()

-- | Runs pointed at different files have nothing to fight over.
lockIsPerStore :: Assertion
lockIsPerStore = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let tickets = dir </> "tickets.jsonl"
      mrs = dir </> "mrs.jsonl"
  result <- withStoreLocks [tickets] $ withStoreLocks [mrs] (pure ())
  result @?= Right (Right ())

-- | A run wants both its stores. Holding only the merge requests is still
-- enough to turn a full run away, and it is named as the reason.
lockIsAllOrNothing :: Assertion
lockIsAllOrNothing = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let tickets = dir </> "tickets.jsonl"
      mrs = dir </> "mrs.jsonl"
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
  let store = dir </> "tickets.jsonl"
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
    writeStore store (Map.empty :: Store Issue)
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

-- | Read GitLab's own JSON for a set of records, write it out as a store, read
-- it back, and check nothing changed on the way. This is what makes an
-- incremental run safe: yesterday's file has to decode into the same values we
-- would have fetched today.
roundtripFile :: forall a. Record a => Proxy a -> FilePath -> Assertion
roundtripFile _ path = do
  original <- decodeFixture path :: IO [a]
  assertBool (path <> " has no records") (not (null original))

  withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
    let storePath = dir </> "store"
        store = mergeRecords Map.empty original

    writeStore storePath store
    reread <- readStore storePath :: IO (Either String (Store a))
    case reread of
      Left err -> assertFailure ("re-reading the store failed: " <> err)
      Right store' -> do
        assertEqual "number of records" (Map.size store) (Map.size store')
        assertEqual "keys" (Map.keys store) (Map.keys store')
        assertEqual
          "records"
          (map jsonOf (Map.elems store))
          (map jsonOf (Map.elems store'))

    -- Writing the re-read store again has to be byte for byte identical,
    -- otherwise repeated runs would keep rewriting the same data.
    let storePath' = dir </> "store2"
    Right store' <- readStore storePath :: IO (Either String (Store a))
    writeStore storePath' store'
    first <- BL.readFile storePath
    second <- BL.readFile storePath'
    assertEqual "re-encoding is stable" first second

-- | An entry with notes attached survives the trip through the file, and comes
-- back no longer needing a discussion.
discussionRoundtrips :: Assertion
discussionRoundtrips = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  assertBool "fixture has notes" (not (null notes))

  let path = dir </> "store"
      store = Map.map (setDiscussion notes) (mergeRecords Map.empty issues)
  writeStore path store

  Right store' <- readStore path :: IO (Either String (Store Issue))
  assertEqual "entries" (Map.keys store) (Map.keys store')
  assertEqual
    "entries roundtrip"
    (map toJSON (Map.elems store))
    (map toJSON (Map.elems store'))
  assertEqual
    "notes came back"
    (map (fmap (map note_id) . entryDiscussion) (Map.elems store))
    (map (fmap (map note_id) . entryDiscussion) (Map.elems store'))
  assertBool
    "nothing needs re-fetching"
    (not (any needsDiscussion (Map.elems store')))

  -- The wrapper really is on disk, not just in memory.
  written <- BL.lines <$> BL.readFile path
  case written of
    [] -> assertFailure "nothing was written"
    (line : _) -> case eitherDecode line :: Either String Value of
      Left err -> assertFailure err
      Right (Object o) -> do
        assertBool "has a ticket field" ("ticket" `elem` map fst (KM.toList o))
        assertBool "has a discussion field" ("discussion" `elem` map fst (KM.toList o))
      Right _ -> assertFailure "expected a JSON object per line"

-- | Re-fetching a record must not throw away the discussion we already have.
mergeKeepsDiscussion :: Assertion
mergeKeepsDiscussion = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  let withNotes = Map.map (setDiscussion notes) (mergeRecords Map.empty issues)
      merged = mergeRecords withNotes issues
  assertEqual "same entries" (Map.keys withNotes) (Map.keys merged)
  assertEqual
    "discussions survived"
    (map (fmap length . entryDiscussion) (Map.elems withNotes))
    (map (fmap length . entryDiscussion) (Map.elems merged))
  assertBool "and are still current" (not (any needsDiscussion (Map.elems merged)))

-- | If the record changed after we fetched its discussion, we have to look
-- again; that is what lets an interrupted notes run resume.
changedRecordIsStale :: Assertion
changedRecordIsStale = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  case issues of
    [] -> assertFailure "fixture is empty"
    (issue : _) -> do
      let entry = setDiscussion notes (newEntry issue)
      assertBool "current right after fetching" (not (needsDiscussion entry))

      let touched = entry {entryRecord = bump (entryRecord entry)}
      assertBool "stale once the record moves" (needsDiscussion touched)
  where
    bump i = i {issue_updated_at = fmap (addUTCTime 60) (issue_updated_at i)}

-- | The whole point of storing @discussion_updated_at@: a run over a project
-- that has not moved must not spend a single request on notes it already has.
--
-- This is a full cycle rather than an in-memory check, because the store on
-- disk is what a second run actually sees, and a timestamp that did not
-- survive encoding would make every run re-fetch everything.
secondRunAsksForNothing :: Assertion
secondRunAsksForNothing = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  let path = dir </> "store"

  -- First run: fetch the records, fetch their notes, write.
  writeStore path (Map.map (setDiscussion notes) (mergeRecords Map.empty issues))

  -- Second run: read that back, and let GitLab hand us the same records over
  -- again, which it does for anything modified within a second of our newest.
  Right stored <- readStore path :: IO (Either String (Store Issue))
  let merged = mergeRecords stored issues
  assertEqual "no entries appeared or vanished" (Map.keys stored) (Map.keys merged)
  assertEqual
    "every re-fetched record was one we already had"
    (length issues)
    (alreadyCurrent stored issues)
  assertEqual
    "nothing is requested a second time"
    []
    (Map.keys (Map.filter needsDiscussion merged))

-- | And the converse: a record that really did change is the only one asked
-- about again, so a run costs requests in proportion to what moved.
onlyChangedIsRefetched :: Assertion
onlyChangedIsRefetched = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  notes <- decodeFixture "test/data/notes.jsonl" :: IO [Note]
  let path = dir </> "store"
  writeStore path (Map.map (setDiscussion notes) (mergeRecords Map.empty issues))
  Right stored <- readStore path :: IO (Either String (Store Issue))

  case issues of
    [] -> assertFailure "fixture is empty"
    (issue : _) -> do
      let touched = issue {issue_updated_at = fmap (addUTCTime 60) (issue_updated_at issue)}
          merged = mergeRecords stored [touched]
      assertEqual
        "only the record that moved"
        [issue_iid issue]
        (Map.keys (Map.filter needsDiscussion merged))
      assertEqual "and it is not counted as current" 0 (alreadyCurrent stored [touched])

-- | What a run reports as fetched for nothing.
countsUnchangedRecords :: Assertion
countsUnchangedRecords = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  let store = mergeRecords Map.empty issues
  assertEqual "all of them" (length issues) (alreadyCurrent store issues)
  assertEqual "none against an empty store" 0 (alreadyCurrent (Map.empty :: Store Issue) issues)

changedIsNotCurrent :: Assertion
changedIsNotCurrent = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  let store = mergeRecords Map.empty issues
  case issues of
    [] -> assertFailure "fixture is empty"
    (issue : rest) -> do
      let touched = issue {issue_updated_at = fmap (addUTCTime 60) (issue_updated_at issue)}
      assertEqual "all but the changed one" (length rest) (alreadyCurrent store (touched : rest))

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

missingFileIsEmpty :: Assertion
missingFileIsEmpty = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  result <- readStore (dir </> "does-not-exist") :: IO (Either String (Store Issue))
  case result of
    Left err -> assertFailure ("expected an empty store, got: " <> err)
    Right store -> assertEqual "empty" 0 (Map.size store)

corruptFileFails :: Assertion
corruptFileFails = withSystemTempDirectory "fetch-gitlab-test" $ \dir -> do
  let path = dir </> "store"
  BL.writeFile path "{\"not\": \"an issue\"}\n"
  result <- readStore path :: IO (Either String (Store Issue))
  case result of
    Left err -> assertBool "error names the file and line" ("store:1:" `isInfixOf` err)
    Right _ -> assertFailure "expected a parse failure"

mergeReplaces :: Assertion
mergeReplaces = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  let (old, rest) = splitAt 1 issues
      store = mergeRecords (mergeRecords Map.empty old) issues
  assertEqual "one entry per iid" (length issues) (Map.size store)
  assertEqual "no duplicates" (length rest + 1) (Map.size store)

latestUpdateIsNewest :: Assertion
latestUpdateIsNewest = do
  issues <- decodeFixture "test/data/issues.jsonl" :: IO [Issue]
  let store = mergeRecords Map.empty issues
      expected = maximum [t | Just t <- map recordUpdatedAt issues] :: UTCTime
  assertEqual "newest timestamp" (Just expected) (latestUpdate store)

decodeFixture :: FromJSON a => FilePath -> IO [a]
decodeFixture path = do
  contents <- BL.readFile path
  let ls = filter (not . BL.null) (BL.lines contents)
  traverse decodeOrFail ls
  where
    decodeOrFail line = either (assertFailure . (("decoding " <> path <> ": ") <>)) pure (eitherDecode line)

jsonOf :: ToJSON a => a -> Value
jsonOf = toJSON
