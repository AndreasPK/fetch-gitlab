{-# LANGUAGE OverloadedStrings #-}

-- | What a store holds, independently of where it is kept.
--
-- An entry is one record together with its discussion and the record version
-- that discussion was fetched for. A store is keyed by the project local id
-- (@iid@) of a record, so fetching the same record again simply replaces the
-- old copy.
--
-- Where the entries actually live is 'FetchGitLab.Store.Class.StoreBackend'.
module FetchGitLab.Store
  ( Record (..)
  , Entry (..)
  , Discussion (..)
  , discussionNotes
  , keepDiscussion
  , Store
  , newEntry
  , needsDiscussion
  , setDiscussion
  , latestUpdate
  , mergeRecords
  , alreadyCurrent
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Proxy (Proxy)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)

import GitLab.Types (Issue (..), MergeRequest (..), Note)

-- | Records we can keep in a store.
class (FromJSON a, ToJSON a) => Record a where
  -- | Project local id, unique within the project we fetch from.
  recordKey :: a -> Int

  -- | When the record was last modified, if GitLab told us.
  recordUpdatedAt :: a -> Maybe UTCTime

  -- | What to call this kind of record where a name is needed rather than a
  -- JSON key: the @kind@ column of a table, a log line, an error message.
  recordKind :: Proxy a -> Text

instance Record Issue where
  recordKey = issue_iid
  recordUpdatedAt = issue_updated_at
  recordKind _ = "ticket"

instance Record MergeRequest where
  recordKey = merge_request_iid
  recordUpdatedAt = Just . merge_request_updated_at
  recordKind _ = "mr"

-- | One record together with its discussion.
data Entry a = Entry
  { entryRecord :: a
    -- ^ The ticket or merge request itself.
  , entryDiscussion :: Discussion
    -- ^ Its notes, as far as this run is concerned.
  , entryDiscussionFor :: Maybe UTCTime
    -- ^ The record's @updated_at@ when the discussion was fetched. Lets a
    -- later run tell whether the discussion it has is still current, which is
    -- what makes an interrupted notes run resumable.
  }
  deriving (Show)

-- | What a run is holding of an entry's discussion.
--
-- The third case is what keeps a run's memory in proportion to the project
-- rather than to the whole history of it. Notes are three quarters of a store
-- and a run needs none of their content: it decides what to fetch from
-- 'entryDiscussionFor' and writes what it fetches straight out. Holding
-- every note of every record for the length of a run costs hundreds of
-- megabytes to answer a question nothing asks.
data Discussion
  = -- | No discussion has ever been fetched for this record.
    NeverFetched
  | -- | The notes themselves.
    Notes [Note]
  | -- | There is a discussion in the store, deliberately not read into memory.
    -- Writing the entry leaves whatever is there alone, so this can never
    -- stand in for notes that are missing.
    Kept
  deriving (Show)

-- | The notes, for the cases that have them to give.
--
-- 'Kept' yields 'Nothing' rather than an empty list: it means "not here", and
-- an empty list would say "there are none", which is a different thing and the
-- kind of difference that quietly deletes a discussion.
discussionNotes :: Discussion -> Maybe [Note]
discussionNotes (Notes ns) = Just ns
discussionNotes _ = Nothing

-- | Forget the content of a discussion we have already written out, keeping
-- only the fact that the store has one.
keepDiscussion :: Entry a -> Entry a
keepDiscussion e = case entryDiscussion e of
  Notes _ -> e {entryDiscussion = Kept}
  _ -> e

-- | A record we have not fetched any discussion for yet.
newEntry :: a -> Entry a
newEntry r = Entry r NeverFetched Nothing

-- | Whether the entry's discussion is missing or out of date.
needsDiscussion :: Record a => Entry a -> Bool
needsDiscussion e =
  case entryDiscussion e of
    NeverFetched -> True
    _ -> entryDiscussionFor e /= recordUpdatedAt (entryRecord e)

-- | Attach a freshly fetched discussion, marking it current for the record as
-- it stands now.
setDiscussion :: Record a => [Note] -> Entry a -> Entry a
setDiscussion notes e =
  e
    { entryDiscussion = Notes notes
    , entryDiscussionFor = recordUpdatedAt (entryRecord e)
    }

-- | Entries indexed by 'recordKey'.
type Store a = Map Int (Entry a)

-- | The most recent modification time in the store, if any.
latestUpdate :: Record a => Store a -> Maybe UTCTime
latestUpdate store =
  case mapMaybe (recordUpdatedAt . entryRecord) (Map.elems store) of
    [] -> Nothing
    ts -> Just (maximum ts)

-- | Add freshly fetched records to a store, replacing older copies.
--
-- An existing discussion is carried over rather than dropped; whether it is
-- still current is decided by 'needsDiscussion'.
mergeRecords :: Record a => Store a -> [a] -> Store a
mergeRecords old new = foldr insert old new
  where
    insert r = Map.insertWith carryOver (recordKey r) (newEntry r)
    carryOver fresh existing =
      fresh
        { entryDiscussion = entryDiscussion existing
        , entryDiscussionFor = entryDiscussionFor existing
        }

-- | How many of the fetched records the store already held unchanged.
--
-- Unchanged means the same key at the same 'recordUpdatedAt', which is exactly
-- the condition under which merging the record in changes nothing and its
-- discussion stays current. This is what a run fetched for nothing.
alreadyCurrent :: Record a => Store a -> [a] -> Int
alreadyCurrent old = length . filter unchanged
  where
    unchanged r = case Map.lookup (recordKey r) old of
      Nothing -> False
      Just e -> recordUpdatedAt (entryRecord e) == recordUpdatedAt r
