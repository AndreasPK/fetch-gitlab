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

import FetchGitLab.Store (Entry, Record, Store)

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

  -- | The same as 'storeLoad', but without reading the notes.
  --
  -- Entries whose discussion is in the store come back as 'Kept', which writes
  -- back as "leave what is there alone". A fetch uses this: notes are three
  -- quarters of a store and it needs none of their content, only whether a
  -- discussion is there and what record version it belongs to. Anything that
  -- has to copy the notes -- @--convert@ -- must use 'storeLoad' instead.
  --
  -- The default reads them, for a backend that cannot do better. That is
  -- honest rather than merely convenient: 'Kept' promises the notes are safe
  -- in the store, so a backend that would rewrite the whole thing from what is
  -- in memory must not claim it.
  storeLoadWithoutNotes :: Record a => b -> IO (Either String (Store a))
  storeLoadWithoutNotes = storeLoad

  -- | One entry by its 'FetchGitLab.Store.recordKey', with its discussion.
  --
  -- 'Nothing' means the store does not hold that key, which is a different
  -- thing from a store it could not read: only the second is a 'Left'.
  --
  -- The default reads the whole store and looks in it, which is all a backend
  -- that keeps whole files can do. A backend that can ask for one record
  -- should, because a reader after a single ticket otherwise pays for parsing
  -- every note in the store to answer.
  storeLookup :: Record a => b -> Int -> IO (Either String (Maybe (Entry a)))
  storeLookup b key = fmap (Map.lookup key) <$> storeLoad b

-- | A backend chosen at run time, once the command line has been read.
data SomeStore = forall b. StoreBackend b => SomeStore b

-- | Save a store without claiming to know what changed in it.
storeSaveAll :: (StoreBackend b, Record a) => b -> Store a -> IO ()
storeSaveAll b store = storeSave b store (IntSet.fromList (Map.keys store))
