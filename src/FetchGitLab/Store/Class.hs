{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}

-- | What a place to keep records has to be able to do.
--
-- A backend holds tickets and merge requests together: 'storeLoad' and
-- 'storeSave' pick which by the 'Record' instance they are used at, so one
-- handle serves both. That is what lets a SQLite store be a single file while
-- a JSON lines store is a file per kind.
module FetchGitLab.Store.Class
  ( StoreBackend (..)
  , SomeStore (..)
  , storeSaveAll
  ) where

import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Text (Text)

import FetchGitLab.Store (Record, Store)

-- | A store that tickets and merge requests can be read from and written to.
class StoreBackend b where
  -- | What to call this backend in a log line.
  storeName :: b -> Text

  -- | Where it keeps its data, for a message that has to name it.
  storeLocation :: b -> Text

  -- | Everything the store holds of one kind of record.
  --
  -- 'Left' means the store is there but could not be understood, which aborts
  -- a run: overwriting a store we failed to read would throw away whatever it
  -- held. A store that does not exist yet is an empty one, not a failure.
  storeLoad :: Record a => b -> IO (Either String (Store a))

  -- | Write a store back.
  --
  -- The second argument is the keys that changed since it was loaded. The
  -- store passed is still the whole truth, so a backend may ignore the set and
  -- write all of it; a backend that can write just those entries should,
  -- because this is called at every checkpoint of a run and the alternative is
  -- rewriting the whole store each time.
  --
  -- Entries not in the store must survive: a run only ever loads, adds to and
  -- saves, so a key that is absent has not been deleted, it was never there.
  storeSave :: Record a => b -> Store a -> IntSet -> IO ()

-- | A backend chosen at run time, once the command line has been read.
data SomeStore = forall b. StoreBackend b => SomeStore b

-- | Save a store without claiming to know what changed in it.
storeSaveAll :: (StoreBackend b, Record a) => b -> Store a -> IO ()
storeSaveAll b store = storeSave b store (IntSet.fromList (Map.keys store))
