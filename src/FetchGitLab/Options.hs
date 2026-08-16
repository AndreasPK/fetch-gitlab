{-# LANGUAGE OverloadedStrings #-}

-- | Command line interface of @fetch-gitlab@.
module FetchGitLab.Options
  ( Command (..)
  , Options (..)
  , ConvertOptions (..)
  , ClearOptions (..)
  , Backend (..)
  , parseBackend
  , backendName
  , optionsParser
  , convertParser
  , clearParser
  , commandParser
  , commandParserInfo
  , defaultStoreDir
  , ticketsFile
  , mrsFile
  , dbFile
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

import FetchGitLab.Since (Since, parseSince)

-- | Where a run keeps what it fetches.
data Backend
  = -- | A file of tickets and a file of merge requests, one JSON object per
    -- line. The original format, and still the default.
    JsonLinesBackend
  | -- | A single SQLite database. Shares repeated objects and writes only what
    -- changed at each checkpoint.
    SqliteBackend
  deriving (Eq, Show)

-- | Read a @--backend@, @--from@ or @--to@ argument.
parseBackend :: String -> Either String Backend
parseBackend s = case s of
  "jsonl" -> Right JsonLinesBackend
  "jsonlines" -> Right JsonLinesBackend
  "sqlite" -> Right SqliteBackend
  "sqlite3" -> Right SqliteBackend
  _ -> Left ("unknown backend " <> show s <> ", expected \"jsonl\" or \"sqlite\"")

-- | What to call a backend on the command line and in a log line.
backendName :: Backend -> Text
backendName JsonLinesBackend = "jsonl"
backendName SqliteBackend = "sqlite"

-- | What the command line asked for.
data Command
  = -- | Fetch from GitLab into a store.
    Fetch Options
  | -- | Copy a store from one backend to another, touching no network.
    Convert ConvertOptions
  | -- | Forget when the discussions in a store were fetched, so that the next
    -- run fetches them again.
    ClearTimestamp ClearOptions
  deriving (Show)

-- | Which store to clear the discussion timestamps of.
--
-- The same four ways of naming a store that a fetching run takes, so that
-- clearing one is spelled the same as fetching into it.
data ClearOptions = ClearOptions
  { clearBackend :: Backend
  , clearTicketsFile :: Maybe FilePath
  , clearMrsFile :: Maybe FilePath
  , clearDbFile :: Maybe FilePath
  , clearVerbose :: Bool
  }
  deriving (Show)

-- | Copying one store into another.
data ConvertOptions = ConvertOptions
  { convFrom :: Backend
    -- ^ Backend to read.
  , convTo :: Backend
    -- ^ Backend to write.
  , convInput :: FilePath
    -- ^ The store to read: the database file for @sqlite@, the directory
    -- holding @tickets.jsonl@ and @mrs.jsonl@ for @jsonl@.
  , convOutput :: FilePath
    -- ^ Where to write it, named the same way.
  , convVerbose :: Bool
  }
  deriving (Show)

-- | Everything the tool needs to know to do its job.
data Options = Options
  { optTokenFile :: FilePath
    -- ^ File holding the GitLab personal access token.
  , optServerUrl :: Text
    -- ^ Base URL of the GitLab instance.
  , optProject :: Text
    -- ^ Project to fetch from, as @namespace/project@.
  , optTicketsFile :: Maybe FilePath
    -- ^ Where to write the issues, in JSON lines format. Defaults to
    -- @tickets.jsonl@ under 'defaultStoreDir'.
  , optMrsFile :: Maybe FilePath
    -- ^ Where to write the merge requests, in JSON lines format. Defaults to
    -- @mrs.jsonl@ under 'defaultStoreDir'.
  , optBackend :: Backend
    -- ^ Which store format to use.
  , optDbFile :: Maybe FilePath
    -- ^ Where to keep the SQLite database, when that is the backend. Defaults
    -- to @gitlab.db@ under 'defaultStoreDir'.
  , optSince :: Maybe Since
    -- ^ Fetch records modified after this, instead of after the newest one
    -- already stored.
  , optNotes :: Bool
    -- ^ Whether to fetch the discussion of each ticket and merge request.
  , optVerbose :: Bool
    -- ^ Log at trace level rather than info level.
  , optLogFile :: Maybe FilePath
    -- ^ Also write the log to this file, at trace level whatever the terminal
    -- is set to.
  }
  deriving (Show)

defaultServerUrl :: Text
defaultServerUrl = "https://gitlab.haskell.org"

defaultProject :: Text
defaultProject = "ghc/ghc"

optionsParser :: Parser Options
optionsParser =
  Options
    <$> strOption
      ( long "token"
          <> metavar "FILE"
          <> help "File containing the GitLab personal access token"
      )
    <*> option
      text
      ( long "url"
          <> metavar "URL"
          <> value defaultServerUrl
          <> showDefault
          <> help "Base URL of the GitLab instance"
      )
    <*> option
      text
      ( long "project"
          <> metavar "NAMESPACE/PROJECT"
          <> value defaultProject
          <> showDefault
          <> help "Project to fetch issues and merge requests from"
      )
    <*> ticketsOption
    <*> mrsOption
    <*> backendOption
    <*> dbOption
    <*> optional
      ( option
          since
          ( long "since"
              <> metavar "WHEN"
              <> help
                ( "Fetch everything modified after WHEN, instead of after the newest "
                    <> "record already stored. Either a date (2026-08-01), an ISO 8601 "
                    <> "timestamp (2026-08-01T12:00:00Z), or a relative time such as "
                    <> "\"2 weeks\" or \"6 months ago\""
                )
          )
      )
    <*> notesFlag
    <*> verboseOption
    <*> optional
      ( strOption
          ( long "log"
              <> metavar "FILE"
              <> help
                ( "Also write the log to FILE, at trace level whatever the terminal "
                    <> "is set to: one line per HTTP request, so that a run which has "
                    <> "stopped can be told from one that is still working. Appended to"
                )
          )
      )
  where
    text = T.pack <$> str

    since = eitherReader parseSince

    -- One request per ticket and merge request, so this is by far the
    -- expensive part of a cold run; --no-notes skips it.
    notesFlag =
      flag'
        False
        ( long "no-notes"
            <> help "Do not fetch the discussion of each ticket and merge request"
        )
        <|> flag'
          True
          ( long "notes"
              <> help "Fetch the discussion of each ticket and merge request (default)"
          )
        <|> pure True

-- The four ways of saying which store is meant. Shared so that a maintenance
-- command names a store exactly as a fetching run does.

ticketsOption :: Parser (Maybe FilePath)
ticketsOption =
  optional
    ( strOption
        ( long "tickets"
            <> metavar "FILE"
            <> help
              ( "Issues file, one JSON object per line, with --backend jsonl "
                  <> "(default: ~/.fetch-gitlab/tickets.jsonl)"
              )
        )
    )

mrsOption :: Parser (Maybe FilePath)
mrsOption =
  optional
    ( strOption
        ( long "mrs"
            <> metavar "FILE"
            <> help
              ( "Merge requests file, one JSON object per line, with --backend jsonl "
                  <> "(default: ~/.fetch-gitlab/mrs.jsonl)"
              )
        )
    )

backendOption :: Parser Backend
backendOption =
  option
    (eitherReader parseBackend)
    ( long "backend"
        <> metavar "jsonl|sqlite"
        <> value SqliteBackend
        <> showDefaultWith (T.unpack . backendName)
        <> help
          ( "Which store format. \"sqlite\" is a single database, sharing repeated "
              <> "objects and writing only what changed at each checkpoint; \"jsonl\" "
              <> "is the two JSON lines files, rewritten in full each time"
          )
    )

dbOption :: Parser (Maybe FilePath)
dbOption =
  optional
    ( strOption
        ( long "db"
            <> metavar "FILE"
            <> help
              ( "Database to use with --backend sqlite "
                  <> "(default: ~/.fetch-gitlab/gitlab.db)"
              )
        )
    )

verboseOption :: Parser Bool
verboseOption =
  switch
    ( long "verbose"
        <> short 'v'
        <> help "Log at trace level"
    )

-- | @--clear-timestamp@ and what it needs.
clearParser :: Parser ClearOptions
clearParser =
  flag'
    ()
    ( long "clear-timestamp"
        <> help
          ( "Forget when the discussions in a store were fetched, so that the next "
              <> "run fetches every one of them again"
          )
    )
    *> (ClearOptions <$> backendOption <*> ticketsOption <*> mrsOption <*> dbOption <*> verboseOption)

-- | @--convert@ and what it needs.
--
-- A separate parser rather than a mode of the fetching one, because none of
-- what fetching requires applies: converting talks to no server, so demanding
-- a @--token@ for it would be asking for something that will not be used.
convertParser :: Parser ConvertOptions
convertParser =
  flag'
    ()
    ( long "convert"
        <> help "Copy a store from one backend to another instead of fetching from GitLab"
    )
    *> ( ConvertOptions
          <$> option
            (eitherReader parseBackend)
            ( long "from"
                <> metavar "jsonl|sqlite"
                <> help "Backend of the store to read"
            )
          <*> option
            (eitherReader parseBackend)
            ( long "to"
                <> metavar "jsonl|sqlite"
                <> help "Backend of the store to write"
            )
          <*> strOption
            ( long "input-path"
                <> metavar "PATH"
                <> help
                  ( "Store to read: the database file for sqlite, the directory "
                      <> "holding tickets.jsonl and mrs.jsonl for jsonl"
                  )
            )
          <*> strOption
            ( long "output-path"
                <> metavar "PATH"
                <> help "Store to write, named the same way as --input-path"
            )
          <*> switch
            ( long "verbose"
                <> short 'v'
                <> help "Log at trace level"
            )
       )

-- | Either of the two things this program does.
commandParser :: Parser Command
commandParser =
  Convert <$> convertParser
    <|> ClearTimestamp <$> clearParser
    <|> Fetch <$> optionsParser

-- | Where the stores live unless told otherwise: @~\/.fetch-gitlab@.
defaultStoreDir :: IO FilePath
defaultStoreDir = (</> ".fetch-gitlab") <$> getHomeDirectory

-- | Where to keep the issues.
ticketsFile :: Options -> IO FilePath
ticketsFile = storeFile "tickets.jsonl" . optTicketsFile

-- | Where to keep the merge requests.
mrsFile :: Options -> IO FilePath
mrsFile = storeFile "mrs.jsonl" . optMrsFile

-- | Where to keep the SQLite database.
dbFile :: Options -> IO FilePath
dbFile = storeFile "gitlab.db" . optDbFile

storeFile :: FilePath -> Maybe FilePath -> IO FilePath
storeFile _ (Just given) = pure given
storeFile name Nothing = (</> name) <$> defaultStoreDir

commandParserInfo :: ParserInfo Command
commandParserInfo =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc
          ( "Fetch all issues and merge requests of a GitLab project into a store, "
              <> "or with --convert copy an existing store between backends"
          )
        <> header "fetch-gitlab - dump GitLab issues and merge requests"
    )
