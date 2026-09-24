{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Forgetting when a store's discussions were fetched.

A discussion is only fetched again once the record it hangs off has moved:
'FetchGitLab.Store.entryDiscussionFor' records the @updated_at@ the notes
were fetched for, and a run compares it against the record's current one.
That is what keeps a run proportional to what changed, and it is also what
makes a discussion that was stored wrong permanently invisible — the store
believes it is current, so nothing ever looks again.

Clearing those timestamps is the way out. The notes themselves are kept, so
the store stays usable until each is replaced; only the claim that they are
up to date is dropped.
-}
module FetchGitLab.ClearTimestamp (
    runClearTimestamp,
    clearTimestamps,
) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import System.Exit (exitFailure)

import GitLab.Types (Issue, MergeRequest)

import Log (LogLevel (..), LogT, Logger, MonadLog, logAttention_, logInfo_, runLogT)
import Log.Backend.StandardOutput (withStdOutLogger)

import FetchGitLab.Lock (LockBusy (..), LockInfo (..), lockPath, withStoreLocks)
import FetchGitLab.Options (ClearOptions (..))
import FetchGitLab.Store (Record (..))
import FetchGitLab.Store.Backend (clearSpec, describeSpec, specPaths, withStore)
import FetchGitLab.Store.Class (SomeStore (..), StoreBackend (..))

-- | Run a @--clear-timestamp@.
runClearTimestamp :: ClearOptions -> IO ()
runClearTimestamp opts = withStdOutLogger $ \logger -> do
    spec <- clearSpec opts
    let runLog :: Logger -> LogT IO a -> IO a
        runLog l = runLogT "fetch-gitlab" l (if clearVerbose opts then LogTrace else LogInfo)

    -- We use the lock to avoid duplicating work, hours of it in the worst case for
    -- a full fetch.
    locked <-
        withStoreLocks (specPaths spec) . withStore spec $ \(SomeStore store) ->
            runLog logger $ do
                logInfo_ ("Store: " <> storeName store <> " at " <> describeSpec spec)
                clearTimestamps store
    case locked of
        Right () -> pure ()
        Left busy -> runLog logger $ do
            logAttention_ $
                "Another fetch-gitlab is using " <> T.pack (busyStore busy) <> holder busy
            logAttention_ $ "Its lock is held on " <> T.pack (lockPath (busyStore busy))
            liftIO exitFailure
  where
    holder busy = case busyHolder busy of
        Nothing -> ""
        Just i ->
            ": pid " <> tshow (lockPid i) <> ", started " <> tshow (lockStartedAt i)

-- | Drop the discussion timestamps of both kinds of record.
clearTimestamps :: (StoreBackend b, MonadLog m, MonadIO m) => b -> m ()
clearTimestamps backend = do
    clear "tickets" (Proxy :: Proxy Issue)
    clear "merge requests" (Proxy :: Proxy MergeRequest)
  where
    clear :: forall a m'. (Record a, MonadLog m', MonadIO m') => Text -> Proxy a -> m' ()
    clear what proxy = do
        -- One statement, so the notes are never read and a store with a
        -- project's whole history in it costs no memory to clear.
        cleared <- liftIO (storeClearDiscussionStamps backend proxy)
        held <- liftIO (storeRecordCount backend proxy)
        wanted <- liftIO (length <$> storeDiscussionPlan backend proxy)
        logInfo_ $
            "Cleared the discussion timestamp of "
                <> tshow cleared
                <> " of "
                <> tshow held
                <> " "
                <> what
                <> "; the next run will fetch "
                <> tshow wanted
                <> " discussions"
        newest <- liftIO (storeLatestUpdate backend proxy)
        reportWatermark what newest

{- | Say what the records themselves will be fetched from, and how to go back
further.

Clearing timestamps does not touch that. A run works out where to start from
the newest @updated_at@ it holds, which is a property of the records
themselves rather than a timestamp anything could clear: the only way to ask
for records from earlier is @--since@.
-}
reportWatermark :: (MonadLog m) => Text -> Maybe UTCTime -> m ()
reportWatermark what newest' = case newest' of
    Nothing ->
        logInfo_ ("No " <> what <> " stored, so the next run fetches all of them")
    Just newest ->
        logInfo_ $
            "The "
                <> what
                <> " themselves are still fetched from "
                <> tshow newest
                <> " onwards; to go back further use --since, for example --since \"1 year\""

tshow :: (Show a) => a -> Text
tshow = T.pack . show
