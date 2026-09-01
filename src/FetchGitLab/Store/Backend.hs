{-# LANGUAGE OverloadedStrings #-}

-- | Naming a store, and opening the one that was named.
--
-- Kept apart from the backends themselves so that neither has to know the
-- other exists, and from 'FetchGitLab.Fetch' so that fetching only ever sees
-- 'FetchGitLab.Store.Class.StoreBackend'.
module FetchGitLab.Store.Backend
  ( StoreSpec (..)
  , optionsSpec
  , clearSpec
  , namedSpec
  , specPaths
  , describeSpec
  , detectSpec
  , withStore
  ) where

import Data.List (sortOn)
import Data.Maybe (listToMaybe)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getModificationTime
  , listDirectory
  )
import System.FilePath (takeExtension, (</>))

import FetchGitLab.Options (Backend (..), ClearOptions (..), Options (..), defaultStoreDir)
import FetchGitLab.Store.Class (SomeStore (..))
import FetchGitLab.Store.Sqlite (withSqliteStore)

-- | A store, said in full: which backend and where.
data StoreSpec
  = SqliteSpec FilePath
    -- ^ The database file.
  deriving (Eq, Show)

-- | A store named the way the command line names one: a backend, and the path
-- that backend keeps its data at.
namedSpec :: Backend -> Maybe FilePath -> IO StoreSpec
namedSpec backend db = case backend of
  SqliteBackend -> SqliteSpec <$> orDefault dbName db
  where
    orDefault _ (Just given) = pure given
    orDefault name Nothing = (</> name) <$> defaultStoreDir

-- | What a run calls the file it writes, where something other than a run has
-- to go looking for it.
dbName :: FilePath
dbName = "gitlab.db"

-- | The store a fetching run was told to use.
optionsSpec :: Options -> IO StoreSpec
optionsSpec opts = namedSpec (optBackend opts) (optDbFile opts)

-- | The store a @--clear-timestamp@ was told to use.
clearSpec :: ClearOptions -> IO StoreSpec
clearSpec opts = namedSpec (clearBackend opts) (clearDbFile opts)

-- | The store to read out of a directory that may hold more than one.
--
-- Whichever was written to most recently wins. That is not a guess at which
-- one the reader meant so much as which one is being kept up to date: a run
-- writes exactly one store, so the newer file is the one it is filling and the
-- older is whatever was there before.
--
-- For SQLite that means the write ahead log as well as the database. A run
-- checkpoints into @gitlab.db-wal@ and only folds it back in when it closes,
-- so during a fetch — the very time someone is likely to be reading — the
-- database file's own timestamp can be hours stale.
--
-- Nothing means the directory holds no store, which is for the caller to
-- report: this creates nothing.
detectSpec :: FilePath -> IO (Maybe StoreSpec)
detectSpec dir = do
  there <- doesDirectoryExist dir
  if not there
    then pure Nothing
    else do
      entries <- listDirectory dir
      databases <-
        traverse
          (\path -> fmap (\t -> (t, SqliteSpec path)) <$> freshest [path, path <> "-wal"])
          [dir </> e | e <- entries, takeExtension e == ".db"]
      let found = concatMap (maybe [] pure) databases
      pure (snd <$> listToMaybe (sortOn (Down . fst) found))

-- | When any of these files was last written, if any of them are there.
freshest :: [FilePath] -> IO (Maybe UTCTime)
freshest paths = do
  times <- traverse stamp paths
  pure $ case concatMap (maybe [] pure) times of
    [] -> Nothing
    ts -> Just (maximum ts)
  where
    stamp path = do
      exists <- doesFileExist path
      if exists then Just <$> getModificationTime path else pure Nothing

-- | The files a run has to hold for itself.
--
-- Worked out from the specification rather than from an open store, because
-- the lock is taken before anything is opened: a run that is going to be
-- turned away should not have created a database first.
specPaths :: StoreSpec -> [FilePath]
specPaths (SqliteSpec path) = [path]

describeSpec :: StoreSpec -> Text
describeSpec (SqliteSpec path) = T.pack path

-- | Open the store, and close it afterwards.
withStore :: StoreSpec -> (SomeStore -> IO a) -> IO a
withStore (SqliteSpec path) act = withSqliteStore path (act . SomeStore)
