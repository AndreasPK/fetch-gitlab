{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The on-disk JSON lines store of tickets and merge requests.
--
-- Each line is an object wrapping one record together with its discussion:
--
-- > {"ticket": {...}, "discussion": [...], "discussion_updated_at": "..."}
--
-- A store is keyed by the project local id (@iid@) of a record, so fetching
-- the same record again simply replaces the old copy.
module FetchGitLab.Store
  ( Record (..)
  , Entry (..)
  , Store
  , newEntry
  , needsDiscussion
  , setDiscussion
  , readStore
  , writeStore
  , latestUpdate
  , mergeRecords
  , alreadyCurrent
  ) where

import Data.Aeson
  ( FromJSON (..)
  , Key
  , ToJSON (..)
  , eitherDecode
  , object
  , withObject
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.Bifunctor (first)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Time.Clock (UTCTime)
import System.Directory (doesFileExist, renameFile)

import GitLab.Types (Issue (..), MergeRequest (..), Note)

import FetchGitLab.JsonLines (writeJsonLines)

-- | Records we can keep in a store.
class (FromJSON a, ToJSON a) => Record a where
  -- | Project local id, unique within the project we fetch from.
  recordKey :: a -> Int

  -- | When the record was last modified, if GitLab told us.
  recordUpdatedAt :: a -> Maybe UTCTime

  -- | The JSON field the record itself is stored under.
  recordField :: Proxy a -> Key

instance Record Issue where
  recordKey = issue_iid
  recordUpdatedAt = issue_updated_at
  recordField _ = "ticket"

instance Record MergeRequest where
  recordKey = merge_request_iid
  recordUpdatedAt = Just . merge_request_updated_at
  recordField _ = "mr"

-- | One record together with its discussion.
data Entry a = Entry
  { entryRecord :: a
    -- ^ The ticket or merge request itself.
  , entryDiscussion :: Maybe [Note]
    -- ^ Its notes, or 'Nothing' if we have never fetched them.
  , entryDiscussionFor :: Maybe UTCTime
    -- ^ The record's @updated_at@ when the discussion was fetched. Lets a
    -- later run tell whether the discussion it has is still current, which is
    -- what makes an interrupted notes run resumable.
  }
  deriving (Show)

instance Record a => ToJSON (Entry a) where
  toJSON e =
    object $
      (recordField (Proxy :: Proxy a) .= entryRecord e)
        : catMaybes
          [ ("discussion" .=) <$> entryDiscussion e
          , ("discussion_updated_at" .=) <$> entryDiscussionFor e
          ]

instance Record a => FromJSON (Entry a) where
  parseJSON = withObject "Entry" $ \o -> do
    record <- o .: recordField (Proxy :: Proxy a)
    Entry record <$> o .:? "discussion" <*> o .:? "discussion_updated_at"

-- | A record we have not fetched any discussion for yet.
newEntry :: a -> Entry a
newEntry r = Entry r Nothing Nothing

-- | Whether the entry's discussion is missing or out of date.
needsDiscussion :: Record a => Entry a -> Bool
needsDiscussion e =
  case entryDiscussion e of
    Nothing -> True
    Just _ -> entryDiscussionFor e /= recordUpdatedAt (entryRecord e)

-- | Attach a freshly fetched discussion, marking it current for the record as
-- it stands now.
setDiscussion :: Record a => [Note] -> Entry a -> Entry a
setDiscussion notes e =
  e
    { entryDiscussion = Just notes
    , entryDiscussionFor = recordUpdatedAt (entryRecord e)
    }

-- | Entries indexed by 'recordKey'.
type Store a = Map Int (Entry a)

-- | Read a store from a JSON lines file. A missing file is an empty store.
--
-- Parsing is all-or-nothing on purpose: a partially readable file would
-- otherwise be silently truncated when we write it back out.
readStore :: forall a. Record a => FilePath -> IO (Either String (Store a))
readStore path = do
  exists <- doesFileExist path
  if not exists
    then pure (Right Map.empty)
    else do
      contents <- BL.readFile path
      let ls = filter (not . BL.null) (BL.lines contents)
      pure $ toStore <$> traverse decodeLine (zip [1 :: Int ..] ls)
  where
    decodeLine (lineNo, line) =
      first (\err -> path <> ":" <> show lineNo <> ": " <> err) (eitherDecode line)

    toStore entries = Map.fromList [(recordKey (entryRecord e), e) | e <- entries]

-- | Write a store out as JSON lines, ordered by key.
--
-- The file is written to a temporary path and renamed into place, so an
-- interrupted run cannot leave a half written store behind.
writeStore :: Record a => FilePath -> Store a -> IO ()
writeStore path store = do
  writeJsonLines tmpPath (Map.elems store)
  renameFile tmpPath path
  where
    tmpPath = path <> ".tmp"

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
    insert r = Map.insertWith keepDiscussion (recordKey r) (newEntry r)
    keepDiscussion fresh existing =
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
