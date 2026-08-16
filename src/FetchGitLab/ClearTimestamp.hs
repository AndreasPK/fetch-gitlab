{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Forgetting when a store's discussions were fetched.
--
-- A discussion is only fetched again once the record it hangs off has moved:
-- 'FetchGitLab.Store.entryDiscussionFor' records the @updated_at@ the notes
-- were fetched for, and a run compares it against the record's current one.
-- That is what keeps a run proportional to what changed, and it is also what
-- makes a discussion that was stored wrong permanently invisible — the store
-- believes it is current, so nothing ever looks again.
--
-- Clearing those timestamps is the way out. The notes themselves are kept, so
-- the store stays usable until each is replaced; only the claim that they are
-- up to date is dropped.
module FetchGitLab.ClearTimestamp
  ( runClearTimestamp
  , clearTimestamps
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure)

import GitLab.Types (Issue, MergeRequest)

import Log (LogLevel (..), LogT, Logger, MonadLog, logAttention_, logInfo_, runLogT)
import Log.Backend.StandardOutput (withStdOutLogger)

import FetchGitLab.Lock (LockBusy (..), LockInfo (..), lockPath, withStoreLocks)
import FetchGitLab.Options (ClearOptions (..))
import FetchGitLab.Store
  ( Entry (..)
  , Record (..)
  , Store
  , latestUpdate
  , needsDiscussion
  )
import FetchGitLab.Store.Backend (clearSpec, describeSpec, specPaths, withStore)
import FetchGitLab.Store.Class (SomeStore (..), StoreBackend (..))

-- | Run a @--clear-timestamp@.
runClearTimestamp :: ClearOptions -> IO ()
runClearTimestamp opts = withStdOutLogger $ \logger -> do
  spec <- clearSpec opts
  let runLog :: Logger -> LogT IO a -> IO a
      runLog l = runLogT "fetch-gitlab" l (if clearVerbose opts then LogTrace else LogInfo)

  -- Held for the same reason a fetching run holds it: this rewrites the store,
  -- and a run writing to it at the same time would undo half of the work.
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
    clear what _ = do
      loaded <- liftIO (storeLoad backend :: IO (Either String (Store a)))
      case loaded of
        Left err -> do
          logAttention_ ("Cannot read " <> what <> ": " <> T.pack err)
          liftIO exitFailure
        Right store -> do
          let cleared = Map.map (\e -> e {entryDiscussionFor = Nothing}) store
              -- Only the entries that claimed to be current need rewriting.
              touched = IntSet.fromList [k | (k, e) <- Map.toList store, isJust (entryDiscussionFor e)]
              wanted = length (filter needsDiscussion (Map.elems cleared))
          liftIO (storeSave backend cleared touched)
          logInfo_ $
            "Cleared the discussion timestamp of "
              <> tshow (IntSet.size touched)
              <> " of "
              <> tshow (Map.size store)
              <> " "
              <> what
              <> "; the next run will fetch "
              <> tshow wanted
              <> " discussions"
          reportWatermark what store

-- | Say what the records themselves will be fetched from, and how to go back
-- further.
--
-- Clearing timestamps does not touch that. A run works out where to start from
-- the newest @updated_at@ it holds, which is a property of the records
-- themselves rather than a timestamp anything could clear: the only way to ask
-- for records from earlier is @--since@.
reportWatermark :: (Record a, MonadLog m) => Text -> Store a -> m ()
reportWatermark what store = case latestUpdate store of
  Nothing ->
    logInfo_ ("No " <> what <> " stored, so the next run fetches all of them")
  Just newest ->
    logInfo_ $
      "The "
        <> what
        <> " themselves are still fetched from "
        <> tshow newest
        <> " onwards; to go back further use --since, for example --since \"1 year\""

tshow :: Show a => a -> Text
tshow = T.pack . show
