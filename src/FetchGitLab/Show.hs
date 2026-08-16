{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | @show-gl-ghc@: printing one ticket or merge request out of a local store.
--
-- Read only and offline. It opens no connection, wants no token, and shares
-- everything it knows about a store with @fetch-gitlab@ rather than parsing
-- one for itself, so a change to the format cannot leave the two disagreeing.
--
-- It also takes no lock. The store may well be one a fetch is writing to,
-- which is when someone is most likely to want to look in it; SQLite lets a
-- reader in while a writer works, and a JSON lines store is renamed into place
-- whole, so a reader sees one version or the other and never half of each.
module FetchGitLab.Show
  ( ShowOptions (..)
  , Target (..)
  , parseTarget
  , showParserInfo
  , resolveStore
  , runShow
  , renderIssue
  , renderMergeRequest
  ) where

import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Options.Applicative
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

import GitLab.Types
  ( Issue (..)
  , MergeRequest (..)
  , Milestone (..)
  , Note (..)
  , Owner (..)
  , User (..)
  )

import FetchGitLab.Options (defaultStoreDir)
import FetchGitLab.Store (Discussion (..), Entry (..))
import FetchGitLab.Store.Backend (StoreSpec, describeSpec, detectSpec, withStore)
import FetchGitLab.Store.Class (SomeStore (..), StoreBackend (..))

-- | What @show-gl-ghc show@ was asked for.
data ShowOptions = ShowOptions
  { showTarget :: Target
    -- ^ The record to print.
  , showStoreDir :: Maybe FilePath
    -- ^ Directory to look for a store in. Defaults to
    -- 'FetchGitLab.Options.defaultStoreDir'.
  , showFull :: Bool
    -- ^ Print the discussion as well as the record.
  }
  deriving (Show)

-- | A record named the way GitLab names one.
data Target
  = Ticket Int
  | Mr Int
  deriving (Eq, Show)

-- | Read a @#123@ or @!123@ argument.
--
-- A bare number is a ticket, because @#@ starts a comment in an interactive
-- shell and @show-gl-ghc show #123@ therefore arrives here as no argument at
-- all. @!@ has no such problem outside of history expansion, but the pair is
-- worth keeping symmetrical.
parseTarget :: String -> Either String Target
parseTarget s = case s of
  ('#' : rest) -> Ticket <$> number rest
  ('!' : rest) -> Mr <$> number rest
  _ -> Ticket <$> number s
  where
    -- Digits and nothing else: 'reads' would take " 12" and "12  " as well,
    -- and an argument with a space in it is a mistake rather than a number.
    number t = case reads t of
      [(n, "")] | n > 0, all isDigit t -> Right n
      _ ->
        Left $
          "expected #123 for a ticket or !123 for a merge request, got "
            <> show s
            <> " (quote the # so the shell does not eat it)"

showParserInfo :: ParserInfo ShowOptions
showParserInfo =
  info
    (subparser (command "show" (info (showOptions <**> helper) showDesc)) <**> helper)
    ( fullDesc
        <> progDesc "Print one ticket or merge request out of a fetch-gitlab store"
        <> header "show-gl-ghc - read a fetch-gitlab store"
    )
  where
    showDesc = progDesc "Print the ticket '#123' or the merge request '!123'"

showOptions :: Parser ShowOptions
showOptions =
  ShowOptions
    <$> argument
      (eitherReader parseTarget)
      ( metavar "#TICKET|!MR"
          <> help "Record to print, as '#123' for a ticket or '!123' for a merge request"
      )
    <*> optional
      ( strOption
          ( long "store"
              <> metavar "DIR"
              <> help
                ( "Directory holding the store. The most recently written of the "
                    <> "*.db and tickets.jsonl/mrs.jsonl in it is the one read "
                    <> "(default: ~/.fetch-gitlab)"
                )
          )
      )
    <*> switch
      ( long "full"
          <> help "Also print the discussion"
      )

-- | Which store to read, given what @--store@ said.
resolveStore :: Maybe FilePath -> IO (Either Text StoreSpec)
resolveStore given = do
  dir <- maybe defaultStoreDir pure given
  found <- detectSpec dir
  pure $ case found of
    Just spec -> Right spec
    Nothing ->
      Left $
        "No store in "
          <> T.pack dir
          <> ": expected a .db file, or tickets.jsonl and mrs.jsonl"

-- | Run a @show@.
runShow :: ShowOptions -> IO ()
runShow opts = do
  resolved <- resolveStore (showStoreDir opts)
  case resolved of
    Left err -> abort err
    Right spec -> withStore spec (look spec)
  where
    look spec (SomeStore st) = case showTarget opts of
      Ticket iid -> do
        found <- storeLookup st iid
        emit spec ("ticket #" <> tshow iid) (fmap (renderIssue (showFull opts)) <$> found)
      Mr iid -> do
        found <- storeLookup st iid
        emit spec ("merge request !" <> tshow iid) (fmap (renderMergeRequest (showFull opts)) <$> found)

    emit spec what result = case result of
      Left err -> abort ("Cannot read " <> describeSpec spec <> ": " <> T.pack err)
      Right Nothing -> abort ("No " <> what <> " in " <> describeSpec spec)
      Right (Just text) -> T.putStr text

abort :: Text -> IO a
abort message = do
  hPutStrLn stderr (T.unpack message)
  exitFailure

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

renderIssue :: Bool -> Entry Issue -> Text
renderIssue full e =
  layout
    full
    ("#" <> tshow (issue_iid i))
    (issue_title i)
    [ ("state", Just (issue_state i))
    , ("author", user <$> issue_author i)
    , ("created", time <$> issue_created_at i)
    , ("updated", time <$> issue_updated_at i)
    , ("labels", commas (fromMaybe [] (issue_labels i)))
    , ("milestone", milestone_title <$> issue_milestone i)
    , ("assignees", commas (map user (fromMaybe [] (issue_assignees i))))
    , ("url", Just (issue_web_url i))
    ]
    (issue_description i)
    (entryDiscussion e)
  where
    i = entryRecord e

renderMergeRequest :: Bool -> Entry MergeRequest -> Text
renderMergeRequest full e =
  layout
    full
    ("!" <> tshow (merge_request_iid m))
    (merge_request_title m)
    [ ("state", Just (merge_request_state m <> draft))
    , ("author", Just (user (merge_request_author m)))
    , ("created", Just (time (merge_request_created_at m)))
    , ("updated", Just (time (merge_request_updated_at m)))
    , ("branches", Just (merge_request_source_branch m <> " -> " <> merge_request_target_branch m))
    , ("merge", Just (merge_request_merge_status m))
    , ("labels", commas (merge_request_labels m))
    , ("milestone", milestone_title <$> merge_request_milestone m)
    , ("assignees", commas (map user (fromMaybe [] (merge_request_assignees m))))
    , ("reviewers", commas (map user (fromMaybe [] (merge_request_reviewers m))))
    , ("url", merge_request_web_url m)
    ]
    (merge_request_description m)
    (entryDiscussion e)
  where
    m = entryRecord e
    draft = if merge_request_work_in_progress m then " (draft)" else ""

-- | The shape both kinds are printed in: a heading, a block of named fields,
-- the description, and with @--full@ the discussion.
--
-- A field with nothing to say is left out rather than printed empty, so what
-- is on screen is what the store actually holds.
layout :: Bool -> Text -> Text -> [(Text, Maybe Text)] -> Maybe Text -> Discussion -> Text
layout full ref title fields description discussion =
  T.unlines $
    [ref <> "  " <> title]
      <> map field shown
      <> [""]
      <> body
      <> notes
  where
    shown =
      [ (name, said)
      | (name, Just said) <- fields <> [("discussion", Just about)]
      , not (T.null said)
      ]
    width = maximum (1 : map (T.length . fst) shown)
    field (name, said) = "  " <> T.justifyLeft width ' ' name <> "  " <> said

    body = case T.strip (fromMaybe "" description) of
      "" -> []
      text -> [text, ""]

    about = case discussion of
      NeverFetched -> "not fetched"
      Kept -> "in the store, not loaded"
      Notes [] -> "none"
      Notes ns ->
        tshow (length ns)
          <> " notes"
          <> if full then "" else " (--full to show them)"

    notes = case (full, discussion) of
      (True, Notes ns) -> concat (zipWith (note (length ns)) [1 ..] ns)
      _ -> []

note :: Int -> Int -> Note -> [Text]
note total position n =
  [ "--- "
      <> tshow position
      <> "/"
      <> tshow total
      <> "  "
      <> owner (note_author n)
      <> "  "
      <> time (note_created_at n)
      <> system
  , T.strip (fromMaybe "" (note_body n))
  , ""
  ]
  where
    system = if note_system n == Just True then "  [system]" else ""

user :: User -> Text
user u = user_name u <> " (@" <> user_username u <> ")"

owner :: Owner -> Text
owner o = owner_name o <> maybe "" (\u -> " (@" <> u <> ")") (owner_username o)

commas :: [Text] -> Maybe Text
commas [] = Nothing
commas xs = Just (T.intercalate ", " xs)

time :: UTCTime -> Text
time = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M"

tshow :: Show a => a -> Text
tshow = T.pack . show
