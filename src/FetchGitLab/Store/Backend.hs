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
  , withStore
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import System.FilePath ((</>))

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
    JsonLinesSpec <$> orDefault "tickets.jsonl" tickets <*> orDefault "mrs.jsonl" mrs
  SqliteBackend -> SqliteSpec <$> orDefault "gitlab.db" db
  where
    orDefault _ (Just given) = pure given
    orDefault name Nothing = (</> name) <$> defaultStoreDir

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
pathSpec JsonLinesBackend dir = JsonLinesSpec (dir </> "tickets.jsonl") (dir </> "mrs.jsonl")
pathSpec SqliteBackend path = SqliteSpec path

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
