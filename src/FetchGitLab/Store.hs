{-# LANGUAGE OverloadedStrings #-}

{- | What a store holds, independently of where it is kept.

An entry is one record together with its discussion and the record version
that discussion was fetched for. A store is keyed by the project local id
(@iid@) of a record, so fetching the same record again simply replaces the
old copy.

'Entry' and 'Store' are the /reader's/ view: what comes back out of
'FetchGitLab.Store.Class.storeLoad'. A run never assembles one. It writes
what it just learned — a page of records, or one record's notes — and asks
the store what is still missing; see
'FetchGitLab.Store.Class.storeWriteRecords' and
'FetchGitLab.Store.Class.storeDiscussionPlan'.
-}
module FetchGitLab.Store (
    Record (..),
    Entry (..),
    Store,
    needsDiscussion,
) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict (Map)
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

    {- | What to call this kind of record where a name is needed rather than a
    JSON key: the @kind@ column of a table, a log line, an error message.
    -}
    recordKind :: Proxy a -> Text

instance Record Issue where
    recordKey = issue_iid
    recordUpdatedAt = issue_updated_at
    recordKind _ = "ticket"

instance Record MergeRequest where
    recordKey = merge_request_iid
    recordUpdatedAt = Just . merge_request_updated_at
    recordKind _ = "mr"

-- | One record together with its discussion, as read back out of a store.
data Entry a = Entry
    { entryRecord :: a
    -- ^ The ticket or merge request itself.
    , entryNotes :: Maybe [Note]
    {- ^ Its notes; 'Nothing' where the store holds none, which is either a
    discussion never fetched or one that was fetched and was empty.
    'entryDiscussionFor' is what tells those apart.
    -}
    , entryDiscussionFor :: Maybe UTCTime
    {- ^ The record's @updated_at@ when the discussion was fetched, and
    'Nothing' if it never was — or if @--clear-timestamp@ dropped the claim.
    Comparing it against the record's current @updated_at@ is what makes an
    interrupted notes run resumable.
    -}
    }
    deriving (Show)

-- | Entries indexed by 'recordKey'.
type Store a = Map Int (Entry a)

{- | Whether the entry's discussion is missing or out of date.

The reader-side twin of the query 'FetchGitLab.Store.Class.storeDiscussionPlan'
runs, and it has to agree with it: what a run asks GitLab for is decided in
SQL, and this is what tests and readers decide by. A stamp that is there and
matches is the only case that is current.
-}
needsDiscussion :: (Record a) => Entry a -> Bool
needsDiscussion e = case entryDiscussionFor e of
    Nothing -> True
    stamp -> stamp /= recordUpdatedAt (entryRecord e)
