{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The SQLite backend.
--
-- The shape of what is stored is 'FetchGitLab.Store.Schema'; this module is
-- the part that talks to the database. Two things about it are worth knowing.
--
-- __It writes only what changed.__ A JSON lines store has to be rewritten from
-- the top at every checkpoint, which over a cold run costs orders of magnitude
-- more writing than the data is worth. Here a checkpoint upserts the entries
-- whose keys the caller passed and leaves the rest alone.
--
-- __It shares repeated objects.__ A user arrives again with every note, and a
-- project has thousands of notes per person. Users and milestones are interned
-- by their exact JSON, so sharing them cannot change what comes back out: two
-- copies that differ in any field stay two rows.
module FetchGitLab.Store.Sqlite
  ( SqliteStore
  , openSqliteStore
  , closeSqliteStore
  , withSqliteStore
  , sqliteStorePath
  , sqliteTableCounts
  ) where

import Control.Exception (bracket)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..), decodeStrict, encode, fromJSON, toJSON)
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Data.Time.Clock (UTCTime)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)

import Database.SQLite.Simple
  ( Connection
  , NamedParam ((:=))
  , Only (..)
  , Query (..)
  , close
  , execute
  , executeNamed
  , execute_
  , open
  , query
  , query_
  , withTransaction
  )

import GitLab.Types (Note)

import FetchGitLab.Store (Discussion (..), Entry (..), Record (..), Store, discussionNotes)
import FetchGitLab.Store.Class (StoreBackend (..))
import FetchGitLab.Store.Schema

-- | An open database, plus the memo tables that keep interning cheap.
data SqliteStore = SqliteStore
  { sqliteStorePath :: FilePath
  , sqliteConn :: Connection
  , sqliteUsers :: IORef (Map Text Int64)
    -- ^ Exact JSON of a user to the row holding it. One lookup per reference
    -- would otherwise be one round trip per note.
  , sqliteMilestones :: IORef (Map Text Int64)
  , sqliteLabels :: IORef (Map Text Int64)
  }

-- | Open a store, creating the file and its tables if they are not there.
openSqliteStore :: FilePath -> IO SqliteStore
openSqliteStore path = do
  createDirectoryIfMissing True (takeDirectory path)
  conn <- open path
  -- Write ahead logging suits a run that checkpoints every twenty objects,
  -- and the foreign keys are worth enforcing in a store that is all
  -- references. NORMAL rather than FULL: a run that loses its last checkpoint
  -- to a power cut re-fetches it, which is the same thing an interrupted JSON
  -- lines run does.
  execute_ conn "PRAGMA journal_mode = WAL"
  execute_ conn "PRAGMA synchronous = NORMAL"
  execute_ conn "PRAGMA foreign_keys = ON"
  mapM_ (execute_ conn . Query) schemaStatements
  checkVersion conn
  SqliteStore path conn <$> newIORef Map.empty <*> newIORef Map.empty <*> newIORef Map.empty

-- | Fold the write ahead log back into the database before letting go of it,
-- so that what is left behind is one file rather than three.
closeSqliteStore :: SqliteStore -> IO ()
closeSqliteStore st = do
  _ <- (query_ (sqliteConn st) "PRAGMA wal_checkpoint(TRUNCATE)" :: IO [(Int, Int, Int)])
  close (sqliteConn st)

withSqliteStore :: FilePath -> (SqliteStore -> IO a) -> IO a
withSqliteStore path = bracket (openSqliteStore path) closeSqliteStore

-- | Refuse a store written by a different schema rather than reading the wrong
-- columns out of it.
checkVersion :: Connection -> IO ()
checkVersion conn = do
  stored <- query_ conn "SELECT value FROM meta WHERE key = 'schema_version'"
  case stored of
    [] ->
      execute
        conn
        "INSERT INTO meta (key, value) VALUES ('schema_version', ?)"
        (Only version)
    (Only v : _)
      | v == version -> pure ()
      | otherwise ->
          ioError . userError $
            "store was written by schema version "
              <> T.unpack v
              <> ", this is version "
              <> show schemaVersion
  where
    version = T.pack (show schemaVersion)

-- | How many rows each table holds. Says whether the sharing the schema is
-- built around is actually happening.
sqliteTableCounts :: SqliteStore -> IO [(Text, Int)]
sqliteTableCounts st =
  forM tables $ \t -> do
    rows <- query_ (sqliteConn st) (Query ("SELECT count(*) FROM " <> t))
    pure (t, case rows of (Only n : _) -> n; [] -> 0)
  where
    tables = ["records", "notes", "users", "milestones", "labels", "record_users", "note_users"]

instance StoreBackend SqliteStore where
  storeName _ = "sqlite"
  storeLocation = T.pack . sqliteStorePath

  storeLoad :: forall a. Record a => SqliteStore -> IO (Either String (Store a))
  storeLoad st = loadKind WithNotes st (recordKind (Proxy :: Proxy a))

  storeLoadWithoutNotes :: forall a. Record a => SqliteStore -> IO (Either String (Store a))
  storeLoadWithoutNotes st = loadKind WithoutNotes st (recordKind (Proxy :: Proxy a))

  storeSave :: forall a. Record a => SqliteStore -> Store a -> IntSet -> IO ()
  storeSave st store dirty =
    withTransaction (sqliteConn st) $
      forM_ (IntSet.toList dirty) $ \iid ->
        -- A key with no entry has not been deleted; a run only ever adds, so
        -- it was never there in the first place.
        forM_ (Map.lookup iid store) (writeEntry st (recordKind (Proxy :: Proxy a)) iid)

-- ---------------------------------------------------------------------------
-- Writing
-- ---------------------------------------------------------------------------

-- | Replace one record and everything hanging off it.
--
-- The relations are deleted and written again rather than diffed: a record
-- that came back from GitLab may have gained or lost assignees and labels, and
-- its discussion may have been refetched entirely.
writeEntry :: Record a => SqliteStore -> Text -> Int -> Entry a -> IO ()
writeEntry st kind iid e = do
  let value = toJSON (entryRecord e)
      (rest, lifted) = splitObject recordSpec value
      conn = sqliteConn st

  milestoneRow <- traverse (internMilestone st) (liftedMilestone lifted)

  execute conn "DELETE FROM record_users WHERE kind = ? AND iid = ?" (kind, iid)
  execute conn "DELETE FROM record_labels WHERE kind = ? AND iid = ?" (kind, iid)

  -- 'Kept' means the notes are in the store and were never read in, so there
  -- is nothing here to write them back from. Deleting them would be deleting
  -- them for good.
  case entryDiscussion e of
    Kept -> pure ()
    _ -> do
      execute conn "DELETE FROM note_users WHERE kind = ? AND iid = ?" (kind, iid)
      execute conn "DELETE FROM notes WHERE kind = ? AND iid = ?" (kind, iid)

  executeNamed
    conn
    "INSERT OR REPLACE INTO records \
    \ (kind, iid, milestone_row, discussion_updated_at, has_discussion, rest, lifted) \
    \ VALUES \
    \ (:kind, :iid, :milestone_row, :discussion_updated_at, :has_discussion, :rest, :lifted)"
    [ ":kind" := kind
    , ":iid" := iid
    , ":milestone_row" := milestoneRow
    , ":discussion_updated_at" := fmap encodeTime (entryDiscussionFor e)
    , ":has_discussion" := case entryDiscussion e of
        NeverFetched -> 0 :: Int
        _ -> 1
    , ":rest" := encodeText rest
    , ":lifted" := encodeText (toJSON (liftedKeys lifted))
    ]

  forM_ (liftedUsers lifted) $ \(field, position, user) -> do
    row <- internUser st user
    execute
      conn
      "INSERT OR REPLACE INTO record_users (kind, iid, field, position, user_row) \
      \ VALUES (?, ?, ?, ?, ?)"
      (kind, iid, field, position, row)

  forM_ (liftedLabels lifted) $ \(position, name) -> do
    label <- internLabel st name
    execute
      conn
      "INSERT OR REPLACE INTO record_labels (kind, iid, position, label_id) VALUES (?, ?, ?, ?)"
      (kind, iid, position, label)

  forM_ (discussionNotes (entryDiscussion e)) $ \notes ->
    forM_ (zip [0 :: Int ..] notes) (uncurry (writeNote st kind iid))

writeNote :: SqliteStore -> Text -> Int -> Int -> Note -> IO ()
writeNote st kind iid position note = do
  let value = toJSON note
      (rest, lifted) = splitObject noteSpec value
      conn = sqliteConn st

  executeNamed
    conn
    "INSERT OR REPLACE INTO notes (kind, iid, position, rest, lifted) \
    \ VALUES (:kind, :iid, :position, :rest, :lifted)"
    [ ":kind" := kind
    , ":iid" := iid
    , ":position" := position
    , ":rest" := encodeText rest
    , ":lifted" := encodeText (toJSON (liftedKeys lifted))
    ]

  forM_ (liftedUsers lifted) $ \(field, _, user) -> do
    row <- internUser st user
    execute
      conn
      "INSERT OR REPLACE INTO note_users (kind, iid, position, field, user_row) \
      \ VALUES (?, ?, ?, ?, ?)"
      (kind, iid, position, field, row)

-- ---------------------------------------------------------------------------
-- Interning
-- ---------------------------------------------------------------------------

internUser :: SqliteStore -> Value -> IO Int64
internUser st value = intern (sqliteUsers st) key $ do
  execute (sqliteConn st) "INSERT OR IGNORE INTO users (json) VALUES (?)" (Only key)
  rowOf (sqliteConn st) "SELECT row_id FROM users WHERE json = ?" key
  where
    key = encodeText value

internMilestone :: SqliteStore -> Value -> IO Int64
internMilestone st value = intern (sqliteMilestones st) key $ do
  execute (sqliteConn st) "INSERT OR IGNORE INTO milestones (json) VALUES (?)" (Only key)
  rowOf (sqliteConn st) "SELECT row_id FROM milestones WHERE json = ?" key
  where
    key = encodeText value

internLabel :: SqliteStore -> Text -> IO Int64
internLabel st name = intern (sqliteLabels st) name $ do
  execute (sqliteConn st) "INSERT OR IGNORE INTO labels (name) VALUES (?)" (Only name)
  rowOf (sqliteConn st) "SELECT label_id FROM labels WHERE name = ?" name

-- | Look a value up in the memo table, and put it in the database if it is not
-- there yet. The insert is @OR IGNORE@ plus a select rather than a
-- @lastInsertRowId@, because the row may already be there from an earlier run.
intern :: IORef (Map Text Int64) -> Text -> IO Int64 -> IO Int64
intern ref key insert = do
  cached <- readIORef ref
  case Map.lookup key cached of
    Just row -> pure row
    Nothing -> do
      row <- insert
      atomicModifyIORef' ref (\m -> (Map.insert key row m, ()))
      pure row

rowOf :: Connection -> Query -> Text -> IO Int64
rowOf conn q key = do
  rows <- query conn q (Only key)
  case rows of
    (Only row : _) -> pure row
    [] -> ioError (userError ("row vanished after insert: " <> show q))

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- | Read every record of one kind, with its discussion.
--
-- Everything is fetched in a handful of queries and joined up in memory. One
-- query per record would be tens of thousands of round trips for a project the
-- size of GHC's.
-- | Whether a load reads the note bodies or leaves them where they are.
data NoteLoading = WithNotes | WithoutNotes
  deriving (Eq)

loadKind :: forall a. Record a => NoteLoading -> SqliteStore -> Text -> IO (Either String (Store a))
loadKind loading st kind = do
  let conn = sqliteConn st
      wanted = loading == WithNotes

  users <- Map.fromList <$> (query_ conn "SELECT row_id, json FROM users" :: IO [(Int64, Text)])
  milestones <-
    Map.fromList <$> (query_ conn "SELECT row_id, json FROM milestones" :: IO [(Int64, Text)])

  recordRows <-
    query
      conn
      "SELECT iid, milestone_row, discussion_updated_at, has_discussion, rest, lifted \
      \ FROM records WHERE kind = ?"
      (Only kind) ::
      IO [(Int, Maybe Int64, Maybe Text, Int, Text, Text)]

  userRefs <-
    query
      conn
      "SELECT iid, field, position, user_row FROM record_users WHERE kind = ?"
      (Only kind) ::
      IO [(Int, Text, Int, Int64)]

  labelRefs <-
    query
      conn
      "SELECT r.iid, r.position, l.name FROM record_labels r \
      \ JOIN labels l ON l.label_id = r.label_id WHERE r.kind = ?"
      (Only kind) ::
      IO [(Int, Int, Text)]

  -- The two heavy queries of the six, and the reason 'WithoutNotes' exists:
  -- notes outnumber records by an order of magnitude and carry the bodies.
  noteRows <-
    if not wanted
      then pure []
      else
        query
          conn
          "SELECT iid, position, rest, lifted FROM notes WHERE kind = ? \
          \ ORDER BY iid, position"
          (Only kind) ::
          IO [(Int, Int, Text, Text)]

  noteRefs <-
    if not wanted
      then pure []
      else
        query
          conn
          "SELECT iid, position, field, user_row FROM note_users WHERE kind = ?"
          (Only kind) ::
          IO [(Int, Int, Text, Int64)]

  let usersByIid = groupOn (\(iid, _, _, _) -> iid) userRefs
      labelsByIid = groupOn (\(iid, _, _) -> iid) labelRefs
      refsByNote = groupOn (\(iid, pos, _, _) -> (iid, pos)) noteRefs
      notesByIid = groupOn (\(iid, _, _, _) -> iid) noteRows

      resolveUser :: Int64 -> Either String Value
      resolveUser row = look "user" users row

      notesFor iid =
        forM (Map.findWithDefault [] iid notesByIid) $ \(_, pos, rest, lifted) -> do
          base <- decodeValue "note" rest
          keys <- decodeValue "note lifted keys" lifted >>= parseValue "lifted keys"
          refs <-
            traverse
              (\(_, _, f, r) -> (,) f <$> resolveUser r)
              (Map.findWithDefault [] (iid, pos) refsByNote)
          let l =
                Lifted
                  { liftedUsers = [(f, 0, v) | (f, v) <- refs]
                  , liftedMilestone = Nothing
                  , liftedLabels = []
                  , liftedKeys = keys
                  }
          parseValue "note" (spliceObject noteSpec l base) :: Either String Note

  pure $ fmap Map.fromList . forM recordRows $
    \(iid, milestoneRow, discussionFor, hasDiscussion, rest, lifted) -> do
      base <- decodeValue "record" rest
      keys <- decodeValue "record lifted keys" lifted >>= parseValue "lifted keys"
      refs <-
        traverse
          (\(_, f, p, r) -> (,,) f p <$> resolveUser r)
          (Map.findWithDefault [] iid usersByIid)
      milestone <- traverse (look "milestone" milestones) milestoneRow
      let l =
            Lifted
              { liftedUsers = refs
              , liftedMilestone = milestone
              , liftedLabels = sortOn fst [(p, n) | (_, p, n) <- Map.findWithDefault [] iid labelsByIid]
              , liftedKeys = keys
              }
      record <- parseValue "record" (spliceObject recordSpec l base) :: Either String a
      discussion <-
        if hasDiscussion == (0 :: Int)
          then pure NeverFetched
          else if wanted then Notes <$> notesFor iid else pure Kept
      discussionAt <- traverse decodeTime discussionFor
      pure
        ( iid
        , Entry
            { entryRecord = record
            , entryDiscussion = discussion
            , entryDiscussionFor = discussionAt
            }
        )
  where
    look what m row = case Map.lookup row m of
      Just json -> decodeValue what json
      Nothing -> Left (T.unpack kind <> ": no " <> what <> " row " <> show row)

    groupOn f = Map.fromListWith (flip (<>)) . map (\x -> (f x, [x]))

decodeValue :: String -> Text -> Either String Value
decodeValue what t = case decodeStrict (encodeUtf8 t) of
  Just v -> Right v
  Nothing -> Left (what <> ": stored JSON did not parse")

parseValue :: Aeson.FromJSON b => String -> Value -> Either String b
parseValue what v = case fromJSON v of
  Aeson.Success x -> Right x
  Aeson.Error err -> Left (what <> ": " <> err)

encodeText :: Value -> Text
encodeText = decodeUtf8 . BL.toStrict . encode

-- | Timestamps go in as the text aeson would have written, without its quotes,
-- so that the column reads well in a query and still comes back bit for bit.
-- Using aeson's own printer and parser is the point: the staleness check
-- compares this against the record's @updated_at@, and a timestamp that lost a
-- digit on the way through would make every run refetch every discussion.
encodeTime :: UTCTime -> Text
encodeTime = T.dropAround (== '"') . decodeUtf8 . BL.toStrict . encode

decodeTime :: Text -> Either String UTCTime
decodeTime t = case decodeStrict (encodeUtf8 ("\"" <> t <> "\"")) of
  Just u -> Right u
  Nothing -> Left ("could not read stored timestamp " <> show t)
