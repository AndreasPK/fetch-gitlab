{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The JSON lines backend: a file of tickets and a file of merge requests.
--
-- This is the original format and still the default. It cannot write part of
-- a store, so every checkpoint rewrites a whole file; see
-- 'FetchGitLab.Store.Sqlite' for the backend that can.
module FetchGitLab.Store.JsonLines
  ( JsonLinesStore (..)
  , openJsonLinesStore
  ) where

import Data.IntSet (IntSet)
import Data.Proxy (Proxy (..))
import qualified Data.Text as T
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import FetchGitLab.Store (Record (..), Store, readStore, writeStore)
import FetchGitLab.Store.Class (StoreBackend (..))

-- | The two files a JSON lines store lives in.
data JsonLinesStore = JsonLinesStore
  { jsonTicketsPath :: FilePath
  , jsonMrsPath :: FilePath
  }

-- | Make sure the directories exist. Nothing is opened until it is used, since
-- the files are read and written whole.
openJsonLinesStore :: FilePath -> FilePath -> IO JsonLinesStore
openJsonLinesStore tickets mrs = do
  mapM_ (createDirectoryIfMissing True . takeDirectory) [tickets, mrs]
  pure (JsonLinesStore tickets mrs)

-- | Which of the two files a record kind lives in.
pathFor :: Record a => JsonLinesStore -> Proxy a -> FilePath
pathFor st p = case recordKind p of
  "mr" -> jsonMrsPath st
  _ -> jsonTicketsPath st

instance StoreBackend JsonLinesStore where
  storeName _ = "jsonl"
  storeLocation st = T.pack (jsonTicketsPath st) <> " and " <> T.pack (jsonMrsPath st)

  storeLoad :: forall a. Record a => JsonLinesStore -> IO (Either String (Store a))
  storeLoad st = readStore (pathFor st (Proxy :: Proxy a))

  -- The changed keys are no use here: a line cannot be replaced in place, so
  -- the file is written out again from the top.
  storeSave :: forall a. Record a => JsonLinesStore -> Store a -> IntSet -> IO ()
  storeSave st store _ = writeStore (pathFor st (Proxy :: Proxy a)) store
