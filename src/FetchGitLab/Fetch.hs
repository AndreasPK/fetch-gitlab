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
  ) where

import Control.Exception (try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteString.Lazy as BL
import Data.Default (def)
import Data.List (partition, sortOn)
import qualified Data.Map.Strict as Map
import Data.Maybe (isNothing)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Network.HTTP.Client (Response, responseStatus)
import Network.HTTP.Types.Status (statusCode)
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError, isPermissionError)

import GitLab (GitLab, runGitLabWithManager)
import GitLab.API.Issues (IssueFilterAttrs (..), projectIssues)
import GitLab.API.MergeRequests (MergeProjectAttrs (..), mergeRequestsWith, mrAttrs)
import GitLab.API.Notes (issueNotes, mergeRequestNotes)
import GitLab.API.Projects (projectWithPathAndName)
import GitLab.Types
  ( AuthMethod (..)
  , GitLabError (..)
  , GitLabServerConfig (..)
  , Note
  , Project
  )

import Log
  ( LogLevel (..)
  , LogT
  , Logger
  , MonadLog
  , logAttention_
  , logInfo_
  , logTrace_
  , runLogT
  )
import Log.Backend.StandardOutput (withStdOutLogger)

import FetchGitLab.Lock
  ( LockBusy (..)
  , LockInfo (..)
  , lockPath
  , withStoreLocks
  )
import FetchGitLab.Options (Options (..), mrsFile, ticketsFile)
import FetchGitLab.RateLimit (newRateLimiter, rateLimitedManager)
import FetchGitLab.Since (Since, resolveSince)
import FetchGitLab.Store
  ( Entry (..)
  , Record (..)
  , Store
  , alreadyCurrent
  , latestUpdate
  , mergeRecords
  , needsDiscussion
  , readStore
  , setDiscussion
  , writeStore
  )

-- | How many requests per second we allow ourselves.
requestsPerSecond :: Double
requestsPerSecond = 2

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
run opts = withStdOutLogger $ \logger -> do
  ticketsPath <- ticketsFile opts
  mrsPath <- mrsFile opts
  -- The default location is under the home directory and will not exist on a
  -- first run. The lock files are created in there, so this comes first.
  mapM_ (createDirectoryIfMissing True . takeDirectory) [ticketsPath, mrsPath]
  locked <- withStoreLocks [ticketsPath, mrsPath] (runLog logger (fetch ticketsPath mrsPath))
  case locked of
    Right () -> pure ()
    Left busy -> runLog logger $ do
      logAttention_ $
        "Another fetch-gitlab is already running against "
          <> T.pack (busyStore busy)
          <> holder busy
      logAttention_ $
        "Its lock is held on "
          <> T.pack (lockPath (busyStore busy))
          <> "; use --tickets/--mrs to work on a separate store"
      liftIO exitFailure
  where
    runLog :: Logger -> LogT IO a -> IO a
    runLog logger = runLogT "fetch-gitlab" logger logLevel

    -- The lock is only reported as held while its owner is alive, so this
    -- names a process that really is running.
    holder busy = case busyHolder busy of
      Nothing -> ""
      Just i -> ": pid " <> tshow (lockPid i) <> ", started " <> tshow (lockStartedAt i)

    fetch :: FilePath -> FilePath -> LogT IO ()
    fetch ticketsPath mrsPath = do
      token <-
        liftIO (readToken (optTokenFile opts))
          >>= either (\err -> abort ("Cannot read the access token: " <> err)) pure

      tickets <- loadStore "tickets" ticketsPath
      mrs <- loadStore "merge requests" mrsPath

      -- An explicit --since overrides what the stores say.
      override <- liftIO $ traverse resolveNow (optSince opts)
      let ticketsSince = maybe (fetchSince tickets) Just override
          mrsSince = maybe (fetchSince mrs) Just override
      logInfo_ $ "Fetching " <> optProject opts <> " from " <> optServerUrl opts
      logSince "tickets" ticketsSince
      logSince "merge requests" mrsSince

      limiter <- liftIO $ newRateLimiter requestsPerSecond
      manager <- liftIO $ rateLimitedManager limiter
      let gitlab :: MonadIO m => GitLab b -> m (Either GitLabError b)
          gitlab = liftIO . runGitLabWithManager manager (serverConfig opts token)

      result <- gitlab $ do
        prj <- lookupProject (optProject opts)
        newTickets <- projectIssues prj (issueFilters ticketsSince)
        newMrs <- mergeRequestsWith prj (mrFilters mrsSince)
        pure (prj, newTickets, newMrs)

      case result of
        Left err -> abort ("GitLab request failed: " <> tshow err)
        Right (prj, newTickets, newMrs) -> do
          tickets' <- saveStore "tickets" ticketsPath tickets newTickets
          mrs' <- saveStore "merge requests" mrsPath mrs newMrs
          if optNotes opts
            then do
              _ <-
                fetchDiscussions gitlab "tickets" ticketsPath tickets' $
                  \iid -> issueNotes prj iid Nothing Nothing
              _ <-
                fetchDiscussions gitlab "merge requests" mrsPath mrs' $
                  \iid -> mergeRequestNotes prj iid Nothing Nothing
              pure ()
            else logInfo_ "Skipping discussions (--no-notes)"

    logLevel
      | optVerbose opts = LogTrace
      | otherwise = LogInfo

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
  (Record a, MonadLog m, MonadIO m) =>
  (forall b. GitLab b -> m (Either GitLabError b)) ->
  Text ->
  FilePath ->
  Store a ->
  -- | Fetch the notes of one record, given its iid.
  (Int -> GitLab (Either (Response BL.ByteString) [Note])) ->
  m (Store a)
fetchDiscussions gitlab what path store fetch = do
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
      final <- go store 0 todo
      liftIO $ writeStore path final
      logInfo_ $ "Discussions for " <> tshow total <> " " <> what <> " written to " <> T.pack path
      pure final
  where
    -- Newest first, and entries GitLab gave no timestamp for last.
    todo = sortOn (Down . recordUpdatedAt . entryRecord) (filter needsDiscussion (Map.elems store))
    total = length todo
    -- Entries we are not asking about again, which is the point of storing
    -- 'entryDiscussionFor' at all.
    cached = Map.size store - total
    (missing, stale) = partition (isNothing . entryDiscussion) todo

    go acc _ [] = pure acc
    go acc done (e : es) = do
      let iid = recordKey (entryRecord e)
      result <- gitlab (fetch iid)
      acc' <- case result of
        Left err -> do
          logAttention_ $ "Skipping notes for " <> what <> " " <> tshow iid <> ": " <> tshow err
          pure acc
        Right (Left response) -> do
          logAttention_ $
            "Skipping notes for "
              <> what
              <> " "
              <> tshow iid
              <> ": HTTP "
              <> tshow (statusCode (responseStatus response))
          pure acc
        Right (Right notes) -> do
          logTrace_ $ tshow (length notes) <> " notes for " <> what <> " " <> tshow iid
          pure (Map.adjust (setDiscussion notes) iid acc)
      let done' = done + 1
      if done' `mod` checkpointEvery == 0 && not (null es)
        then do
          liftIO $ writeStore path acc'
          logInfo_ $
            "Discussions: " <> tshow done' <> "/" <> tshow total <> " " <> what <> " (checkpointed)"
          go acc' done' es
        else go acc' done' es

-- | Log a reason the run cannot go on, and stop.
abort :: (MonadLog m, MonadIO m) => Text -> m a
abort msg = do
  logAttention_ msg
  liftIO exitFailure

-- | Read a store, aborting if the existing file cannot be parsed.
loadStore :: (Record a, MonadLog m, MonadIO m) => Text -> FilePath -> m (Store a)
loadStore what path = do
  result <- liftIO $ readStore path
  case result of
    Left err -> abort ("Cannot read existing " <> what <> ": " <> T.pack err)
    Right store -> do
      logInfo_ $ "Read " <> tshow (length store) <> " " <> what <> " from " <> T.pack path
      pure store

-- | Merge freshly fetched records into a store and write it back out.
--
-- The count of records we already had at the same @updated_at@ is logged
-- because it says how much of the request was wasted. It is normally small and
-- never zero once a store exists: 'fetchSince' deliberately asks from a second
-- before our newest record, so whatever sits in that second comes back again.
-- A large count means the timestamp we asked from was further back than it
-- needed to be.
saveStore :: (Record a, MonadLog m, MonadIO m) => Text -> FilePath -> Store a -> [a] -> m (Store a)
saveStore what path old new = do
  let merged = mergeRecords old new
      cached = alreadyCurrent old new
  logInfo_ $
    "Fetched "
      <> tshow (length new)
      <> " "
      <> what
      <> " ("
      <> tshow (length new - cached)
      <> " new or changed, "
      <> tshow cached
      <> " already current), writing "
      <> tshow (length merged)
      <> " to "
      <> T.pack path
  liftIO $ writeStore path merged
  pure merged

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

issueFilters :: Maybe UTCTime -> IssueFilterAttrs
issueFilters since = def {issueFilter_updated_after = since}

mrFilters :: Maybe UTCTime -> MergeProjectAttrs
mrFilters since = mrAttrs {mr_attr_updated_after = since}

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
