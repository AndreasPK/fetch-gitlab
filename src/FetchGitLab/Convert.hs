{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Copying a store from one backend to another.
--
-- Nothing here knows what a backend is beyond
-- 'FetchGitLab.Store.Class.StoreBackend': a conversion is a load from one and
-- a save into the other, which is the point of having the class at all. It
-- works between any two backends, the same one at both ends included, so it
-- doubles as a way to copy or rebuild a store.
module FetchGitLab.Convert
  ( runConvert
  , convertStores
  ) where

import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist)
import System.Exit (exitFailure)
import System.FilePath (equalFilePath, takeDirectory)

import GitLab.Types (Issue, MergeRequest)

import Log (LogLevel (..), MonadLog, logAttention_, logInfo_, runLogT)
import Log.Backend.StandardOutput (withStdOutLogger)

import FetchGitLab.Lock (LockBusy (..), LockInfo (..), lockPath, withStoreLocks)
import FetchGitLab.Options (Backend (..), ConvertOptions (..), backendName)
import FetchGitLab.Store (Record (..), Store)
import FetchGitLab.Store.Backend
  ( StoreSpec (..)
  , describeSpec
  , pathSpec
  , specPaths
  , withStore
  )
import FetchGitLab.Store.Class (SomeStore (..), StoreBackend (..), storeSaveAll)

-- | Run a @--convert@.
runConvert :: ConvertOptions -> IO ()
runConvert opts = withStdOutLogger $ \logger -> do
  let level = if convVerbose opts then LogTrace else LogInfo
      runLog = runLogT "fetch-gitlab" logger level
      source = pathSpec (convFrom opts) (convInput opts)
      target = pathSpec (convTo opts) (convOutput opts)

  runLog (checkPaths opts source target)
  mapM_ (createDirectoryIfMissing True . takeDirectory) (specPaths target)

  -- Both ends are locked: the source may be what a fetch is writing to, and
  -- the target may be what another one is reading from.
  locked <-
    withStoreLocks (specPaths source <> specPaths target) $
      withStore source $ \(SomeStore from) ->
        withStore target $ \(SomeStore to) ->
          runLog $ do
            logInfo_ $
              "Converting "
                <> backendName (convFrom opts)
                <> " at "
                <> describeSpec source
                <> " to "
                <> backendName (convTo opts)
                <> " at "
                <> describeSpec target
            refuseNonEmpty to
            convertStores from to
  case locked of
    Right () -> pure ()
    Left busy -> runLog $ do
      logAttention_ $
        "Another fetch-gitlab is using " <> T.pack (busyStore busy) <> holder busy
      logAttention_ $ "Its lock is held on " <> T.pack (lockPath (busyStore busy))
      liftIO exitFailure
  where
    holder busy = case busyHolder busy of
      Nothing -> ""
      Just i ->
        ": pid " <> T.pack (show (lockPid i)) <> ", started " <> T.pack (show (lockStartedAt i))

-- | Copy both kinds of record from one store into another.
convertStores ::
  (StoreBackend from, StoreBackend to, MonadLog m, MonadIO m) => from -> to -> m ()
convertStores from to = do
  copy "tickets" (Proxy :: Proxy Issue)
  copy "merge requests" (Proxy :: Proxy MergeRequest)
  where
    copy :: forall a m'. (Record a, MonadLog m', MonadIO m') => Text -> Proxy a -> m' ()
    copy what _ = do
      loaded <- liftIO (storeLoad from :: IO (Either String (Store a)))
      case loaded of
        Left err -> abort ("Cannot read " <> what <> " from the source store: " <> T.pack err)
        Right store -> do
          liftIO (storeSaveAll to store)
          logInfo_ $ "Copied " <> tshow (length store) <> " " <> what

-- | Converting into a store that already holds something would either merge
-- into it or, for a backend that writes whole files, replace it. Neither is
-- what @--convert@ was asked to do, so it stops instead.
refuseNonEmpty :: (StoreBackend to, MonadLog m, MonadIO m) => to -> m ()
refuseNonEmpty to = do
  tickets <- liftIO (storeLoad to :: IO (Either String (Store Issue)))
  mrs <- liftIO (storeLoad to :: IO (Either String (Store MergeRequest)))
  case (tickets, mrs) of
    -- A target that cannot be read is not a target we should write over
    -- either, so the same answer serves.
    (Left err, _) -> abort ("The output store exists and could not be read: " <> T.pack err)
    (_, Left err) -> abort ("The output store exists and could not be read: " <> T.pack err)
    (Right t, Right m)
      | null t && null m -> pure ()
      | otherwise ->
          abort $
            "The output store is not empty: it already holds "
              <> tshow (length t)
              <> " tickets and "
              <> tshow (length m)
              <> " merge requests. Convert into a new store rather than over an old one"

-- | Paths have to be told apart before either end is opened, since opening the
-- output creates it.
checkPaths :: (MonadLog m, MonadIO m) => ConvertOptions -> StoreSpec -> StoreSpec -> m ()
checkPaths opts source target = do
  overlap <-
    liftIO . fmap or . sequence $
      [ pure (equalFilePath a b)
      | a <- specPaths source
      , b <- specPaths target
      ]
  if overlap
    then abort "The input and output stores are the same; --convert would read what it wrote"
    else pure ()

  present <- liftIO (mapM exists (specPaths source))
  case (convFrom opts, or present) of
    (_, True) -> pure ()
    (JsonLinesBackend, False) ->
      abort $
        "No store to read: expected tickets.jsonl or mrs.jsonl in "
          <> T.pack (convInput opts)
          <> ". For jsonl, --input-path is the directory holding them"
    (SqliteBackend, False) ->
      abort ("No store to read: " <> T.pack (convInput opts) <> " does not exist")
  where
    exists p = (||) <$> doesFileExist p <*> doesDirectoryExist p

abort :: (MonadLog m, MonadIO m) => Text -> m a
abort msg = do
  logAttention_ msg
  liftIO exitFailure

tshow :: Show a => a -> Text
tshow = T.pack . show
