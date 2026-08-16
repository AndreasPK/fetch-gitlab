{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Fetching issues and merge requests from a GitLab server.
--
-- Fetching is incremental: whatever is already in the JSON lines files is read
-- back in, and only records modified since the newest timestamp we have are
-- requested from GitLab.
module FetchGitLab.Fetch
  ( run
  , serverConfig
  , requestsPerSecond
  , readToken
  , waitOutChallenge
  , challengeWaits
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (filterM)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString.Lazy as BL
import Data.Aeson (Value, object)
import Data.Default (def)
import qualified Data.IntSet as IntSet
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Network.HTTP.Client (Response, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import System.Directory (createDirectoryIfMissing, doesFileExist, getFileSize)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError, isPermissionError)

import GitLab (GitLab, runGitLabWithManager, runGitLabWithManagerUnchecked)
import GitLab.API.Issues (IssueFilterAttrs (..), projectIssuesPage)
import GitLab.API.MergeRequests (MergeProjectAttrs (..), mergeRequestsWithPage, mrAttrs)
import GitLab.API.Notes (issueNotes, mergeRequestNotes)
import GitLab.API.Projects (projectWithPathAndName)
import GitLab.Types
  ( AuthMethod (..)
  , GitLabError (..)
  , GitLabServerConfig (..)
  , Note
  , OrderBy (..)
  , Project
  , SortBy (..)
  )

import Log
  ( LogLevel (..)
  , LogT
  , MonadLog
  , getLoggerIO
  , logAttention_
  , logInfo_
  , logTrace_
  , runLogT
  )

import FetchGitLab.Logging (withFetchLogger)
import FetchGitLab.Lock
  ( LockBusy (..)
  , LockInfo (..)
  , lockPath
  , withStoreLocks
  )
import FetchGitLab.Options (Backend (..), Options (..), dbFile, mrsFile, ticketsFile)
import FetchGitLab.RateLimit (newRateLimiter, rateLimitedManager)
import FetchGitLab.Since (Since, resolveSince)
import FetchGitLab.Store
  ( Discussion (..)
  , Entry (..)
  , Record (..)
  , Store
  , alreadyCurrent
  , latestUpdate
  , keepDiscussion
  , mergeRecords
  , needsDiscussion
  , setDiscussion
  )
import FetchGitLab.Store.Backend (optionsSpec, specPaths, withStore)
import FetchGitLab.Store.Class (SomeStore (..), StoreBackend (..))

-- | How many requests per second we allow ourselves.
--
-- Two was enough to draw gitlab.haskell.org's anti-bot check repeatedly during
-- a long discussion phase, so this backs off to below it. The check clears on
-- its own after a few minutes and the requests it refuses are left pending
-- rather than lost, so tripping it costs time rather than data — but a run
-- that does not trip it is a run that does not have to make that good.
requestsPerSecond :: Double
requestsPerSecond = 1.5

-- | How many records to ask for in one page.
--
-- This is the batch the store is written in, so it is also how often a run
-- reports progress. GitLab caps it at 100 and a page is a single request, so
-- asking for less would not report anything sooner -- it would only take more
-- requests to fetch the same collection.
recordsPerPage :: Int
recordsPerPage = 100

-- | Read the access token, which lives in a file so it does not have to be
-- passed on the command line where every process can see it.
--
-- Returns what is wrong rather than throwing. A mistyped @--token@ path is an
-- ordinary user error and deserves a line of explanation, not a backtrace out
-- of 'T.readFile'. An empty file is rejected here too, since it would
-- otherwise surface much later as an unauthorised response.
readToken :: FilePath -> IO (Either Text Text)
readToken path = do
  contents <- try (T.readFile path)
  pure $ case contents of
    Left e
      | isDoesNotExistError e -> Left ("no such file: " <> quoted)
      | isPermissionError e -> Left ("not readable: " <> quoted)
      | otherwise -> Left (quoted <> ": " <> T.pack (ioeGetErrorString e))
    Right raw
      | T.null token -> Left ("no token in " <> quoted <> ", the file is empty")
      | otherwise -> Right token
      where
        token = T.strip raw
  where
    quoted = T.pack (show path)

-- | Server configuration for a server and an already read token.
serverConfig :: Options -> Text -> GitLabServerConfig
serverConfig opts token =
  GitLabServerConfig
    { url = optServerUrl opts
    , authMethod = AuthMethodToken token
    , retries = 5
    , delayBetweenRetries = 1
    , debugSystemHooks = Nothing
    }

-- | Fetch tickets and merge requests and write them out as JSON lines.
--
-- Both stores are locked for the duration. A run reads each store, merges into
-- what it read and writes the whole thing back, so two runs sharing a store
-- would each drop the other's work; the second one is turned away instead.
run :: Options -> IO ()
run opts = withFetchLogger (optLogFile opts) terminalLevel $ \logger level -> do
  let runLog :: LogT IO a -> IO a
      runLog = runLogT "fetch-gitlab" logger level
  runLog (checkForOldStore opts)
  spec <- optionsSpec opts
  let paths = specPaths spec
  -- The default location is under the home directory and will not exist on a
  -- first run. The lock files are created in there, so this comes first.
  mapM_ (createDirectoryIfMissing True . takeDirectory) paths
  locked <-
    withStoreLocks paths . withStore spec $ \(SomeStore store) ->
      runLog $ do
        logInfo_ $ "Store: " <> storeName store <> " at " <> storeLocation store
        fetch store
  case locked of
    Right () -> pure ()
    Left busy -> runLog $ do
      logAttention_ $
        "Another fetch-gitlab is already running against "
          <> T.pack (busyStore busy)
          <> holder busy
      logAttention_ $
        "Its lock is held on "
          <> T.pack (lockPath (busyStore busy))
          <> "; point --tickets/--mrs/--db at a separate store to work alongside it"
      liftIO exitFailure
  where
    -- The lock is only reported as held while its owner is alive, so this
    -- names a process that really is running.
    holder busy = case busyHolder busy of
      Nothing -> ""
      Just i -> ": pid " <> tshow (lockPid i) <> ", started " <> tshow (lockStartedAt i)

    fetch :: StoreBackend b => b -> LogT IO ()
    fetch store = do
      token <-
        liftIO (readToken (optTokenFile opts))
          >>= either (\err -> abort ("Cannot read the access token: " <> err)) pure

      tickets <- loadStore "tickets" store
      mrs <- loadStore "merge requests" store

      -- An explicit --since overrides what the stores say.
      override <- liftIO $ traverse resolveNow (optSince opts)
      let ticketsSince = maybe (fetchSince tickets) Just override
          mrsSince = maybe (fetchSince mrs) Just override
      logInfo_ $ "Fetching " <> optProject opts <> " from " <> optServerUrl opts
      logSince "tickets" ticketsSince
      logSince "merge requests" mrsSince

      limiter <- liftIO $ newRateLimiter requestsPerSecond
      -- Every request announces itself at trace level. On the terminal that is
      -- normally filtered out; in a --log file it is what shows a run pausing
      -- for a slow page rather than having stopped.
      announce <- requestAnnouncer
      manager <- liftIO $ rateLimitedManager limiter announce
      -- Every request a run makes goes through one of these two, so waiting
      -- out a challenge here covers the record pages and the discussions
      -- alike, without either of them having to know what a challenge is.
      let gitlab :: GitLab c -> LogT IO (Either GitLabError c)
          gitlab =
            waitOutChallenge challengeWaits
              . liftIO
              . runGitLabWithManagerUnchecked manager (serverConfig opts token)

      -- The one call that checks the token, so that the thousands to follow do
      -- not each pay for a second request saying the same thing.
      prj <-
        waitOutChallenge
          challengeWaits
          (liftIO (runGitLabWithManager manager (serverConfig opts token) (lookupProject (optProject opts))))
          >>= either (\err -> abort ("GitLab request failed: " <> tshow err)) pure

      tickets' <- fetchRecords gitlab "tickets" store tickets ticketsSince $ \since ->
        projectIssuesPage prj (issueFilters since) recordsPerPage
      mrs' <- fetchRecords gitlab "merge requests" store mrs mrsSince $ \since ->
        mergeRequestsWithPage prj (mrFilters since) recordsPerPage

      if optNotes opts
        then do
          _ <-
            fetchDiscussions gitlab "tickets" store tickets' $
              \iid -> issueNotes prj iid Nothing Nothing
          _ <-
            fetchDiscussions gitlab "merge requests" store mrs' $
              \iid -> mergeRequestNotes prj iid Nothing Nothing
          pure ()
        else logInfo_ "Skipping discussions (--no-notes)"

    terminalLevel
      | optVerbose opts = LogTrace
      | otherwise = LogInfo

-- | How long to wait, in seconds, after each successive anti-bot challenge.
--
-- The challenge clears on its own once traffic drops. Ten minutes was measured
-- to be enough and twenty seconds was measured not to be, so this starts well
-- under the known-good figure — no point waiting ten minutes for something that
-- might clear in one — and ends well over it. The whole ladder is a little
-- under half an hour, which is nothing against a run that takes eight.
challengeWaits :: [Int]
challengeWaits = [30, 60, 120, 300, 600, 600]

-- | Run a GitLab action, waiting out an anti-bot challenge rather than failing
-- on it.
--
-- These come back with HTTP 200 and an HTML body and are transient, so the
-- useful response is to stop asking for a while. Without this a challenge is
-- indistinguishable from a hard failure: a run that starts inside an open one
-- dies on the token check having done nothing, and one that meets it later
-- spends the rest of the run making requests that cannot succeed and marking
-- records for retry it never had a chance to fetch.
--
-- Every other error is returned untouched on the first try, so a bad token
-- still fails immediately rather than after half an hour of politeness.
--
-- Giving up stops the run rather than returning the error to the caller. A
-- caller that skips and carries on would spend the ladder again on the next
-- record, and the one after that; and stopping costs nothing, because whatever
-- has been fetched is already written and the next run resumes from it.
waitOutChallenge ::
  (MonadLog m, MonadIO m) => [Int] -> m (Either GitLabError a) -> m (Either GitLabError a)
waitOutChallenge = go
  where
    go waits act = do
      result <- act
      case result of
        Left (GitLabChallengeError detail) -> case waits of
          [] ->
            abort $
              "The server has been answering with an anti-bot challenge for "
                <> tshow (sum challengeWaits `div` 60)
                <> " minutes, so this run is stopping. Everything fetched so far is "
                <> "written; a later run carries on from there."
          wait : rest -> do
            logAttention_ $
              "The server answered with an anti-bot challenge rather than data. Waiting "
                <> tshow wait
                <> "s before asking again ("
                <> tshow (length rest)
                <> " further attempts before giving up)"
            logTrace_ detail
            liftIO $ threadDelay (wait * 1000000)
            go rest act
        _ -> pure result

-- | A callback the HTTP manager can use to report each request it makes.
--
-- Trace level, so it is the @--log@ file that carries it rather than the
-- terminal, unless @-v@ was asked for.
requestAnnouncer :: MonadLog m => m (Text -> IO ())
requestAnnouncer = do
  logIO <- getLoggerIO
  pure $ \what -> do
    now <- getCurrentTime
    logIO now LogTrace what noData
  where
    noData :: Value
    noData = object []

-- | How many entries to fetch discussions for between checkpoints.
checkpointEvery :: Int
checkpointEvery = 20

-- | Fetch the discussions of every entry that is missing one or whose record
-- has changed since we last looked.
--
-- An entry whose stored discussion still matches its record is skipped, so the
-- one request per object this costs is never spent twice on the same version of
-- an object. The counts are logged: entries already current, entries never
-- fetched, and entries a change made stale. The last of those is the only one
-- that is ever re-requested, and it should track how much the project actually
-- moved since the previous run.
--
-- Entries are visited newest first, so an interrupted run has the most
-- recently touched discussions. The store is written every
-- 'checkpointEvery' entries, which is what makes stopping safe: whatever was
-- fetched is on disk, and the next run picks up the rest.
--
-- A record whose notes cannot be fetched is logged and left alone, so one bad
-- object does not abort a long run. It will be retried next time.
fetchDiscussions ::
  (Record a, StoreBackend s, MonadLog m, MonadIO m) =>
  (forall b. GitLab b -> m (Either GitLabError b)) ->
  Text ->
  s ->
  Store a ->
  -- | Fetch the notes of one record, given its iid.
  (Int -> GitLab (Either (Response BL.ByteString) [Note])) ->
  m (Store a)
fetchDiscussions gitlab what backend store fetch = do
  if null todo
    then do
      logInfo_ $
        "All " <> tshow cached <> " " <> what <> " discussions are up to date, requesting none"
      pure store
    else do
      logInfo_ $
        "Discussions for "
          <> what
          <> ": "
          <> tshow cached
          <> " already current, requesting "
          <> tshow total
          <> " ("
          <> tshow (length missing)
          <> " never fetched, "
          <> tshow (length stale)
          <> " changed since)"
      (final, pending) <- go store 0 IntSet.empty todo
      liftIO $ storeSave backend final pending
      logInfo_ $
        "Discussions for "
          <> tshow total
          <> " "
          <> what
          <> " written to "
          <> storeLocation backend
      pure final
  where
    -- Newest first, and entries GitLab gave no timestamp for last.
    todo = sortOn (Down . recordUpdatedAt . entryRecord) (filter needsDiscussion (Map.elems store))
    total = length todo
    -- Entries we are not asking about again, which is the point of storing
    -- 'entryDiscussionFor' at all.
    cached = Map.size store - total
    (missing, stale) = partition (neverFetched . entryDiscussion) todo
    neverFetched NeverFetched = True
    neverFetched _ = False

    -- The third argument is the entries touched since the last checkpoint. A
    -- backend that can write just those is handed them; one that cannot is
    -- none the worse off.
    go acc _ pending [] = pure (acc, pending)
    go acc done pending (e : es) = do
      let iid = recordKey (entryRecord e)
      result <- gitlab (fetch iid)
      (acc', pending') <- case result of
        Left err -> do
          logAttention_ $ "Skipping notes for " <> what <> " " <> tshow iid <> ": " <> tshow err
          pure (acc, pending)
        Right (Left response) -> do
          logAttention_ $
            "Skipping notes for "
              <> what
              <> " "
              <> tshow iid
              <> ": HTTP "
              <> tshow (statusCode (responseStatus response))
          pure (acc, pending)
        Right (Right notes) -> do
          logTrace_ $ tshow (length notes) <> " notes for " <> what <> " " <> tshow iid
          pure (Map.adjust (setDiscussion notes) iid acc, IntSet.insert iid pending)
      let done' = done + 1
      if done' `mod` checkpointEvery == 0 && not (null es)
        then do
          liftIO $ storeSave backend acc' pending'
          logInfo_ $
            "Discussions: " <> tshow done' <> "/" <> tshow total <> " " <> what <> " (checkpointed)"
          -- Written, so the notes are the store's problem now rather than
          -- ours. Holding them for the rest of the run would make a run's
          -- memory grow with the size of the project's whole history; this
          -- keeps it flat.
          go (forgetWritten pending' acc') done' IntSet.empty es
        else go acc' done' pending' es

-- | Drop the note bodies of the entries a checkpoint has just written.
--
-- Only sound because the store was told to write exactly these keys and did.
forgetWritten :: IntSet.IntSet -> Store a -> Store a
forgetWritten written store = IntSet.foldl' (flip (Map.adjust keepDiscussion)) store written

-- | Stop a run that would silently refetch a project someone already has.
--
-- The default store used to be the JSON lines files and is now the database.
-- Someone who upgrades and runs the same command as yesterday would otherwise
-- start again from nothing: hours of work and tens of thousands of requests to
-- arrive back where they already were. Only the case where nothing was said
-- about where to keep things is caught, since anyone naming a store explicitly
-- has said what they meant.
checkForOldStore :: Options -> LogT IO ()
checkForOldStore opts
  | optBackend opts /= SqliteBackend = pure ()
  | Just _ <- optDbFile opts = pure ()
  | otherwise = do
      db <- liftIO (dbFile opts)
      started <- liftIO (doesFileExist db)
      tickets <- liftIO (ticketsFile opts)
      mrs <- liftIO (mrsFile opts)
      old <- liftIO (filterM hasContent [tickets, mrs])
      case (started, old) of
        (False, kept@(_ : _)) -> do
          logAttention_ $
            "There is a JSON lines store at "
              <> T.intercalate ", " (map T.pack kept)
              <> " but no database at "
              <> T.pack db
          logAttention_
            "The default store is now sqlite, so this run would fetch the project again \
            \from the beginning rather than carry on from what is already there."
          logAttention_ $
            "To keep it:  fetch-gitlab --convert --from jsonl --to sqlite --input-path "
              <> T.pack (takeDirectory tickets)
              <> " --output-path "
              <> T.pack db
          logAttention_ "To carry on as before, pass --backend jsonl."
          liftIO exitFailure
        _ -> pure ()
  where
    hasContent path = do
      there <- doesFileExist path
      if there then (> 0) <$> getFileSize path else pure False

-- | Log a reason the run cannot go on, and stop.
abort :: (MonadLog m, MonadIO m) => Text -> m a
abort msg = do
  logAttention_ msg
  liftIO exitFailure

-- | Read a store, aborting if what is there cannot be parsed.
loadStore :: (Record a, StoreBackend s, MonadLog m, MonadIO m) => Text -> s -> m (Store a)
loadStore what backend = do
  result <- liftIO $ storeLoadWithoutNotes backend
  case result of
    Left err -> abort ("Cannot read existing " <> what <> ": " <> T.pack err)
    Right store -> do
      logInfo_ $ "Read " <> tshow (length store) <> " " <> what <> " from the store"
      pure store

-- | Fetch a collection a page at a time, writing each page to the store before
-- asking for the next one.
--
-- Asking for the whole collection in one call meant minutes with nothing to
-- show and nothing saved: a run that was paging through twenty thousand issues
-- looked exactly like one that had wedged, and stopping it threw all of it
-- away. A page is one request, so writing every page reports progress as often
-- as there is progress to report, without spending a request to do it.
--
-- Pages are anchored on @updated_at@ rather than numbered. Each one asks for
-- the records updated after the newest we have, oldest first, which is what
-- makes stopping halfway safe: the next run derives what to ask for from the
-- newest record in the store, so a store holding the first half of a
-- collection asks for exactly the second half. Numbered pages would break that
-- twice over -- the newest records arrive first, so a partial run would leave
-- a watermark past everything it had not fetched, and a record edited while we
-- page moves within the collection and shifts a neighbour out of the numbering
-- unseen.
--
-- The count of records we already had at the same @updated_at@ is logged
-- because it says how much of the fetch was wasted. It is normally small and
-- never zero once a store exists: 'fetchSince' deliberately asks from a second
-- before our newest record, so whatever sits in that second comes back again.
-- A large count means the timestamp we asked from was further back than it
-- needed to be.
fetchRecords ::
  (Record a, StoreBackend s, MonadLog m, MonadIO m) =>
  (forall b. GitLab b -> m (Either GitLabError b)) ->
  Text ->
  s ->
  Store a ->
  -- | Where to start, or 'Nothing' to fetch the whole collection.
  Maybe UTCTime ->
  -- | One page of records updated at or after the given time, oldest first.
  (Maybe UTCTime -> GitLab [a]) ->
  m (Store a)
fetchRecords gitlab what backend original start page = go original start IntSet.empty 0
  where
    go acc anchor seen cached = do
      result <- gitlab (page (addUTCTime (-overlap) <$> anchor))
      records <- either (\err -> abort ("GitLab request failed: " <> tshow err)) pure result
      let touched = IntSet.fromList (map recordKey records)
          fresh = filter (not . (`IntSet.member` seen) . recordKey) records
          seen' = IntSet.union seen touched
          cached' = cached + alreadyCurrent original fresh
          acc' = mergeRecords acc records
          newest = maximumOf (mapMaybe recordUpdatedAt records)
      liftIO $ storeSave backend acc' touched
      if length records < recordsPerPage
        then do
          let fetched = IntSet.size seen'
          logInfo_ $
            "Fetched "
              <> tshow fetched
              <> " "
              <> what
              <> " ("
              <> tshow (fetched - cached')
              <> " new or changed, "
              <> tshow cached'
              <> " already current), store now holds "
              <> tshow (length acc')
          pure acc'
        else do
          logInfo_ $
            "Fetching "
              <> what
              <> ": "
              <> tshow (IntSet.size seen')
              <> " so far, written up to "
              <> maybe "an unknown time" tshow newest
          case newest of
            Just t | maybe True (t >) anchor -> go acc' (Just t) seen' cached'
            -- A whole page of records sharing one instant, so there is no
            -- later time to ask from. Stepping past it is the only way on;
            -- anything it skips has an older timestamp than the store's
            -- newest record and so comes back on the next run.
            _ -> case anchor of
              Just t -> do
                logAttention_ $
                  "A full page of "
                    <> what
                    <> " is stamped "
                    <> tshow t
                    <> "; stepping past it, some may be left for the next run"
                go acc' (Just (addUTCTime (overlap + tick) t)) seen' cached'
              Nothing -> do
                logAttention_ $
                  "GitLab gave no update time for any of the first "
                    <> tshow recordsPerPage
                    <> " "
                    <> what
                    <> ", so there is nothing to page on; stopping here"
                pure acc'

    -- GitLab reads @updated_after@ as "at or after", so asking from exactly
    -- the newest record we hold returns that record again, which is harmless.
    -- Going back a further millisecond costs one more repeat and covers a
    -- server that reads it as "after".
    overlap = 0.001
    tick = 0.000001

    maximumOf [] = Nothing
    maximumOf ts = Just (maximum ts)

-- | Timestamp to request updates from, or 'Nothing' to fetch everything.
--
-- We go back a second from the newest timestamp we have, so that a record
-- modified in the same instant as our newest one cannot fall through an
-- exclusive @updated_after@ comparison. Re-fetching a record we already have is
-- harmless, it just replaces itself.
fetchSince :: Record a => Store a -> Maybe UTCTime
fetchSince = fmap (addUTCTime (-1)) . latestUpdate

-- | Resolve a @--since@ argument against the current time.
resolveNow :: Since -> IO UTCTime
resolveNow s = flip resolveSince s <$> getCurrentTime

-- | Oldest change first, so that a run stopped halfway leaves a store whose
-- newest record is exactly where the next one should carry on from. See
-- 'fetchRecords'.
issueFilters :: Maybe UTCTime -> IssueFilterAttrs
issueFilters since =
  def
    { issueFilter_updated_after = since
    , issueFilter_order_by = Just UpdatedAt
    , issueFilter_sort = Just Ascending
    }

mrFilters :: Maybe UTCTime -> MergeProjectAttrs
mrFilters since =
  mrAttrs
    { mr_attr_updated_after = since
    , mr_attr_order_by = Just UpdatedAt
    , mr_attr_sort = Just Ascending
    }

-- | Look up the project to fetch from, given as @namespace/project@.
lookupProject :: Text -> GitLab Project
lookupProject fullPath = do
  result <- projectWithPathAndName namespace name
  case result of
    Left _ -> notFound
    Right Nothing -> notFound
    Right (Just prj) -> pure prj
  where
    notFound = throwError (GitLabError ("no such project: " <> fullPath))

    (namespace, name) = case T.breakOnEnd "/" fullPath of
      (ns, n) -> (T.dropEnd 1 ns, n)

logSince :: MonadLog m => Text -> Maybe UTCTime -> m ()
logSince what Nothing = logInfo_ $ "No " <> what <> " stored yet, fetching all of them"
logSince what (Just t) = logInfo_ $ "Fetching " <> what <> " updated after " <> tshow t

tshow :: Show a => a -> Text
tshow = T.pack . show
