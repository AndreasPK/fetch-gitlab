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
  , pathSpec
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
import FetchGitLab.Store.JsonLines (openJsonLinesStore)
import FetchGitLab.Store.Sqlite (withSqliteStore)

-- | A store, said in full: which backend and where.
data StoreSpec
  = JsonLinesSpec FilePath FilePath
    -- ^ The tickets file and the merge requests file.
  | SqliteSpec FilePath
    -- ^ The database file.
  deriving (Eq, Show)

-- | A store named the way the command line names one: a backend, and up to
-- three paths of which only the ones that backend uses matter.
namedSpec :: Backend -> Maybe FilePath -> Maybe FilePath -> Maybe FilePath -> IO StoreSpec
namedSpec backend tickets mrs db = case backend of
  JsonLinesBackend ->
    JsonLinesSpec <$> orDefault ticketsName tickets <*> orDefault mrsName mrs
  SqliteBackend -> SqliteSpec <$> orDefault dbName db
  where
    orDefault _ (Just given) = pure given
    orDefault name Nothing = (</> name) <$> defaultStoreDir

-- | What a run calls the files it writes, where something other than a run has
-- to go looking for them.
ticketsName, mrsName, dbName :: FilePath
ticketsName = "tickets.jsonl"
mrsName = "mrs.jsonl"
dbName = "gitlab.db"

-- | The store a fetching run was told to use.
optionsSpec :: Options -> IO StoreSpec
optionsSpec opts =
  namedSpec (optBackend opts) (optTicketsFile opts) (optMrsFile opts) (optDbFile opts)

-- | The store a @--clear-timestamp@ was told to use.
clearSpec :: ClearOptions -> IO StoreSpec
clearSpec opts =
  namedSpec (clearBackend opts) (clearTicketsFile opts) (clearMrsFile opts) (clearDbFile opts)

-- | A store named by a single path, as @--input-path@ and @--output-path@ do.
--
-- A JSON lines store is two files, so there the path is the directory holding
-- them under the names a run would give them.
pathSpec :: Backend -> FilePath -> StoreSpec
pathSpec JsonLinesBackend dir = JsonLinesSpec (dir </> ticketsName) (dir </> mrsName)
pathSpec SqliteBackend path = SqliteSpec path

-- | The store to read out of a directory that may hold either kind, or both.
--
-- Whichever was written to most recently wins. That is not a guess at which
-- one the reader meant so much as which one is being kept up to date: a run
-- writes exactly one store, so the newer file is the one it is filling and the
-- older is whatever was there before it changed backend.
--
-- For SQLite that means the write ahead log as well as the database. A run
-- checkpoints into @gitlab.db-wal@ and only folds it back in when it closes,
-- so during a fetch — the very time someone is likely to be reading — the
-- database file's own timestamp can be hours stale.
--
-- A tie goes to SQLite, which is the backend a run uses unless told otherwise.
-- Nothing means the directory holds neither, which is for the caller to
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
      pair <- freshest [dir </> ticketsName, dir </> mrsName]
      let jsonl = fmap (\t -> (t, JsonLinesSpec (dir </> ticketsName) (dir </> mrsName))) pair
          -- The sort is stable, so putting the databases first is what decides
          -- a tie.
          found = concatMap toList databases <> toList jsonl
      pure (snd <$> listToMaybe (sortOn (Down . fst) found))
  where
    toList = maybe [] pure

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
specPaths (JsonLinesSpec tickets mrs) = [tickets, mrs]
specPaths (SqliteSpec path) = [path]

describeSpec :: StoreSpec -> Text
describeSpec (JsonLinesSpec tickets mrs) = T.pack tickets <> " and " <> T.pack mrs
describeSpec (SqliteSpec path) = T.pack path

-- | Open the store, and close it afterwards.
withStore :: StoreSpec -> (SomeStore -> IO a) -> IO a
withStore (JsonLinesSpec tickets mrs) act = do
  store <- openJsonLinesStore tickets mrs
  act (SomeStore store)
withStore (SqliteSpec path) act = withSqliteStore path (act . SomeStore)
