{-# LANGUAGE OverloadedStrings #-}

-- | Command line interface of @fetch-gitlab@.
module FetchGitLab.Options
  ( Command (..)
  , Options (..)
  , ClearOptions (..)
  , Backend (..)
  , parseBackend
  , backendName
  , optionsParser
  , commandParser
  , commandParserInfo
  , defaultStoreDir
  , dbFile
  , tokenFile
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

import FetchGitLab.Since (Since, parseSince)

-- | Where a run keeps what it fetches.
--
-- There is only one place today. The type is kept so that adding another --
-- a server rather than a file, say -- is a matter of a constructor and a
-- 'FetchGitLab.Store.Class.StoreBackend' instance rather than of threading a
-- choice back through everything that names a store.
data Backend
  = -- | A single SQLite database. Sharable substructure in MRs/Tickets are
    -- shared as independent tables.
    SqliteBackend
  deriving (Eq, Show)

-- | Read a @--backend@ argument.
parseBackend :: String -> Either String Backend
parseBackend s = case s of
  "sqlite" -> Right SqliteBackend
  "sqlite3" -> Right SqliteBackend
  _ -> Left ("unknown backend " <> show s <> ", expected \"sqlite\"")

-- | What to call a backend on the command line and in a log line.
backendName :: Backend -> Text
backendName SqliteBackend = "sqlite"

-- | What the command line asked for.
data Command
  = -- | Fetch from GitLab into a store.
    Fetch Options
  | -- | Forget when the discussions in a store were fetched, so that the next
    -- run fetches them again.
    ClearTimestamp ClearOptions
  deriving (Show)

-- | Which store to clear the discussion timestamps of.
--
-- The same ways of naming a store that a fetching run takes, so that clearing
-- one is spelled the same as fetching into it.
data ClearOptions = ClearOptions
  { clearBackend :: Backend
  , clearDbFile :: Maybe FilePath
  , clearVerbose :: Bool
  }
  deriving (Show)

-- | Everything the tool needs to know to do its job.
data Options = Options
  { optTokenFile :: Maybe FilePath
    -- ^ File holding the GitLab personal access token. Defaults to
    -- @gitlab-token@ under 'defaultStoreDir'.
  , optServerUrl :: Text
    -- ^ Base URL of the GitLab instance.
  , optProject :: Text
    -- ^ Project to fetch from, as @namespace/project@.
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
  , optPipelines :: Maybe Int
    -- ^ Fetch the pipelines (and their jobs) of this one merge request,
    -- instead of fetching records at all. Pipelines are never fetched
    -- unasked: a project the size of GHC runs one per push, so following
    -- them for every merge request would dwarf the records themselves.
  , optJobLog :: Maybe Int
    -- ^ Fetch a job log by the jobs GitLab id. The job must already be cached.
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
  build
    <$> optional
      ( strOption
          ( long "token"
              <> metavar "FILE"
              <> help
                ( "File containing the GitLab personal access token "
                    <> "(default: ~/.fetch-gitlab/gitlab-token)"
                )
          )
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
    <*> modeFlags
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
    build token url project backend db when_ (notes, pipelines, jobLog) verbose logFile =
      Options token url project backend db when_ notes pipelines jobLog verbose logFile

    text = T.pack <$> str

    since = eitherReader parseSince

    -- What a run fetches: records with or without their discussions, or -- an
    -- entirely separate errand -- one merge request's pipelines or one job's
    -- log. Those alternatives come first because the notes flag defaults to
    -- True and so never fails to parse.
    modeFlags =
      (\mr -> (True, Just mr, Nothing))
        <$> option
          auto
          ( long "pipelines"
              <> metavar "MR"
              <> help
                ( "Fetch the pipelines and jobs of this one merge request, given by "
                    <> "its number, instead of fetching records. Pipelines are only "
                    <> "ever fetched on request"
                )
          )
        <|> (\job -> (True, Nothing, Just job))
          <$> option
            auto
            ( long "job-log"
                <> metavar "JOB_ID"
                <> help
                  ( "Fetch the log of this one job, given by its GitLab id, instead "
                      <> "of fetching records; stored without its terminal control "
                      <> "characters. The job must be in the store already: fetch its "
                      <> "merge request with --pipelines first"
                  )
            )
        <|> (\notes -> (notes, Nothing, Nothing)) <$> notesFlag

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

-- The ways of saying which store is meant. Shared so that a maintenance
-- command names a store exactly as a fetching run does.

backendOption :: Parser Backend
backendOption =
  option
    (eitherReader parseBackend)
    ( long "backend"
        <> metavar "sqlite"
        <> value SqliteBackend
        <> showDefaultWith (T.unpack . backendName)
        <> help
          ( "Which store format. \"sqlite\", the only one, is a single database "
              <> "sharing repeated objects and writing only what the run just fetched"
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

-- | Either of the two things this program does.
--
-- One parser rather than an alternative per command. Two alternatives
-- sharing options -- @--db@, @--backend@, @-v@ -- parse order-sensitively:
-- optparse-applicative only backtracks out of a branch that has consumed
-- nothing, so a shared option followed by a branch-specific one was an
-- \"Invalid option\" whenever the shared one came first. Everything is
-- parsed as one grammar instead, and the command is read off afterwards;
-- the price is that @--clear-timestamp@ quietly accepts and ignores the
-- fetch-only options.
commandParser :: Parser Command
commandParser = classify <$> clearFlag <*> optionsParser
  where
    classify False opts = Fetch opts
    classify True opts =
      ClearTimestamp
        ClearOptions
          { clearBackend = optBackend opts
          , clearDbFile = optDbFile opts
          , clearVerbose = optVerbose opts
          }

    clearFlag =
      switch
        ( long "clear-timestamp"
            <> help
              ( "Forget when the discussions in a store were fetched, so that the next "
                  <> "run fetches every one of them again, instead of fetching"
              )
        )

-- | Where the stores live unless told otherwise: @~\/.fetch-gitlab@.
defaultStoreDir :: IO FilePath
defaultStoreDir = (</> ".fetch-gitlab") <$> getHomeDirectory

-- | Where to keep the SQLite database.
dbFile :: Options -> IO FilePath
dbFile = storeFile "gitlab.db" . optDbFile

-- | Where to read the access token from.
tokenFile :: Options -> IO FilePath
tokenFile = storeFile "gitlab-token" . optTokenFile

storeFile :: FilePath -> Maybe FilePath -> IO FilePath
storeFile _ (Just given) = pure given
storeFile name Nothing = (</> name) <$> defaultStoreDir

commandParserInfo :: ParserInfo Command
commandParserInfo =
  info
    (commandParser <**> helper)
    ( fullDesc
        <> progDesc
          "Fetch all issues and merge requests of a GitLab project into a store"

        <> header "fetch-gitlab - dump GitLab issues and merge requests"
    )
