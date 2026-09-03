{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RankNTypes #-}

-- | What a place to keep records has to be able to do.
--
-- A backend holds tickets and merge requests together: every operation picks
-- which by the 'Record' instance it is used at, so one handle serves both,
-- whether the backend keeps them in one place or two. Where a call has no
-- record to take the instance from it takes a 'Proxy' instead.
--
-- == A write states one thing the run just learned
--
-- There are two of them: 'storeWriteRecords' says "these records are as GitLab
-- had them just now", and 'storeWriteDiscussion' says "these are the notes of
-- record @n@ as of the version I planned against". Neither one restates
-- anything else about the store, so a run holds no snapshot to write back and
-- two runs against one store can only duplicate work — never undo it. What a
-- run still owes is asked for rather than remembered: 'storeDiscussionPlan'.
module FetchGitLab.Store.Class
  ( StoreBackend (..)
  , SomeStore (..)
  ) where

import Data.Aeson (Value)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)

import GitLab.Types (Note)

import FetchGitLab.Store (Entry, Record, Store)

-- | A store that tickets and merge requests can be read from and written to.
class StoreBackend b where
  -- | What to call this backend in a log line.
  storeName :: b -> Text

  -- | Where it keeps its data, for a message that has to name it.
  storeLocation :: b -> Text

  -- | Everything the store holds of one kind of record.
  --
  -- The reader's view, and what the tests compare stores by; a run does not
  -- use it. 'Left' means the store is there but could not be understood. A
  -- store that does not exist yet is an empty one, not a failure.
  storeLoad :: Record a => b -> IO (Either String (Store a))

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

  -- | Write records as GitLab just gave them, replacing any older copy.
  --
  -- Exactly the record and what hangs off it: never a discussion, never a
  -- discussion timestamp. A record that is new to the store arrives with no
  -- timestamp, which is what makes it show up in 'storeDiscussionPlan'; a
  -- record that was already there keeps whatever stamp and notes it had, so a
  -- run rewriting a page cannot undo the notes another writer just fetched.
  --
  -- One transaction for the whole list: a page is written or it is not.
  storeWriteRecords :: Record a => b -> [a] -> IO ()

  -- | Write the notes of one record, and stamp it with the record version
  -- they were fetched for.
  --
  -- The stamp is passed in rather than read from the row, and it is the
  -- @updated_at@ 'storeDiscussionPlan' handed out. In the window between
  -- planning and writing, another run may have written a newer version of the
  -- record; stamping these notes with /that/ version would claim they cover
  -- edits they were fetched before. Using the planned version instead leaves
  -- the record looking stale, so the race costs one redundant refetch next
  -- run, which is the cheap direction to be wrong in.
  --
  -- 'Nothing' means GitLab gave the record no @updated_at@ at all, so nothing
  -- can be claimed for the notes and they are fetched again next run.
  --
  -- One transaction, so a discussion is whole on disk the moment it is
  -- written: an interrupted run loses nothing it had fetched.
  storeWriteDiscussion :: Record a => b -> Proxy a -> Int -> Maybe Text -> [Note] -> IO ()

  -- | The records whose discussion is missing or out of date, each with the
  -- @updated_at@ to stamp its notes with, newest first.
  --
  -- This is the whole of what a run needs to know to fetch notes, and it is a
  -- query rather than a filter over a loaded store: notes are three quarters
  -- of a store and a run needs none of their content.
  storeDiscussionPlan :: Record a => b -> Proxy a -> IO [(Int, Maybe Text)]

  -- | How many records of the kind the store holds. With the length of
  -- 'storeDiscussionPlan' this is what a run reports as already current.
  storeRecordCount :: Record a => b -> Proxy a -> IO Int

  -- | The newest @updated_at@ over the records of one kind, which is where an
  -- incremental run resumes from.
  storeLatestUpdate :: Record a => b -> Proxy a -> IO (Maybe UTCTime)

  -- | The stored @updated_at@ of each of the given keys the store holds.
  --
  -- A key that is not in the map is a record the store does not have; a key
  -- mapped to 'Nothing' is one GitLab gave no timestamp for. Lets a run count
  -- how much of a page it fetched for nothing without holding the store.
  storeRecordVersions :: Record a => b -> Proxy a -> [Int] -> IO (Map Int (Maybe UTCTime))

  -- | Forget when the discussions of one kind were fetched, keeping the notes
  -- themselves; returns how many records were changed. See
  -- "FetchGitLab.ClearTimestamp".
  storeClearDiscussionStamps :: Record a => b -> Proxy a -> IO Int

  -- | Write the pipelines of one record, each paired with the jobs it ran.
  --
  -- The record is named by kind and iid exactly as everywhere else, because
  -- which merge request a pipeline was fetched for is not part of the
  -- pipeline object. The values are the raw JSON the server sent, verbatim;
  -- what to lift out of them is the backend's business. Re-writing a
  -- pipeline or job replaces the previous copy.
  storeWritePipelines :: b -> Text -> Int -> [(Value, [Value])] -> IO ()

-- | A backend chosen at run time, once the command line has been read.
data SomeStore = forall b. StoreBackend b => SomeStore b
