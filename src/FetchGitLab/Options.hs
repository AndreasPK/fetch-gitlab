{-# LANGUAGE OverloadedStrings #-}

-- | Command line interface of @fetch-gitlab@.
module FetchGitLab.Options
  ( Options (..)
  , optionsParser
  , optionsParserInfo
  , defaultStoreDir
  , ticketsFile
  , mrsFile
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Options.Applicative
import System.Directory (getHomeDirectory)
import System.FilePath ((</>))

import FetchGitLab.Since (Since, parseSince)

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
  , optSince :: Maybe Since
    -- ^ Fetch records modified after this, instead of after the newest one
    -- already stored.
  , optNotes :: Bool
    -- ^ Whether to fetch the discussion of each ticket and merge request.
  , optVerbose :: Bool
    -- ^ Log at trace level rather than info level.
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
    <*> optional
      ( strOption
          ( long "tickets"
              <> metavar "FILE"
              <> help
                ( "File to write the issues to, one JSON object per line "
                    <> "(default: ~/.fetch-gitlab/tickets.jsonl)"
                )
          )
      )
    <*> optional
      ( strOption
          ( long "mrs"
              <> metavar "FILE"
              <> help
                ( "File to write the merge requests to, one JSON object per line "
                    <> "(default: ~/.fetch-gitlab/mrs.jsonl)"
                )
          )
      )
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
    <*> switch
      ( long "verbose"
          <> short 'v'
          <> help "Log at trace level"
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

-- | Where the stores live unless told otherwise: @~\/.fetch-gitlab@.
defaultStoreDir :: IO FilePath
defaultStoreDir = (</> ".fetch-gitlab") <$> getHomeDirectory

-- | Where to keep the issues.
ticketsFile :: Options -> IO FilePath
ticketsFile = storeFile "tickets.jsonl" . optTicketsFile

-- | Where to keep the merge requests.
mrsFile :: Options -> IO FilePath
mrsFile = storeFile "mrs.jsonl" . optMrsFile

storeFile :: FilePath -> Maybe FilePath -> IO FilePath
storeFile _ (Just given) = pure given
storeFile name Nothing = (</> name) <$> defaultStoreDir

optionsParserInfo :: ParserInfo Options
optionsParserInfo =
  info
    (optionsParser <**> helper)
    ( fullDesc
        <> progDesc "Fetch all issues and merge requests of a GitLab project as JSON lines"
        <> header "fetch-gitlab - dump GitLab issues and merge requests"
    )
