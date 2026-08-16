{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : GitLab
-- Description : Contains the 'runGitLab' function to run GitLab actions
-- Copyright   : (c) Rob Stewart, Heriot-Watt University, 2019
-- License     : BSD3
-- Maintainer  : robstewart57@gmail.com
-- Stability   : stable
module GitLab
  ( runGitLab,
    runGitLabPassPrompt,
    runGitLabDbg,
    runGitLabWithManager,
    runGitLabWithManagerUnchecked,
    module GitLab.Types,
    module GitLab.API.Pipelines,
    module GitLab.API.Groups,
    module GitLab.API.Members,
    module GitLab.API.Commits,
    module GitLab.API.Projects,
    module GitLab.API.Users,
    module GitLab.API.Issues,
    module GitLab.API.Branches,
    module GitLab.API.Jobs,
    module GitLab.API.JobArtifacts,
    module GitLab.API.MergeRequests,
    module GitLab.API.Repositories,
    module GitLab.API.RepositoryFiles,
    module GitLab.API.Tags,
    module GitLab.API.Todos,
    module GitLab.API.Version,
    module GitLab.API.Notes,
    module GitLab.API.Boards,
    module GitLab.API.Discussions,
    module GitLab.API.Events,
    module GitLab.SystemHooks.GitLabSystemHooks,
    module GitLab.SystemHooks.Types,
    module GitLab.SystemHooks.Rules,
    module Data.Default,
  )
where

import Control.Monad.Except
import Control.Monad.IO.Class
import Control.Monad.Trans.Reader
import Data.Default
import qualified Data.Text as T
import GitLab.API.Boards
import GitLab.API.Branches
import GitLab.API.Commits
import GitLab.API.Discussions
import GitLab.API.Events
import GitLab.API.Groups
import GitLab.API.Issues
import GitLab.API.JobArtifacts
import GitLab.API.Jobs
import GitLab.API.Members
import GitLab.API.MergeRequests
import GitLab.API.Notes
import GitLab.API.Pipelines
import GitLab.API.Projects
import GitLab.API.Repositories
import GitLab.API.RepositoryFiles
import GitLab.API.Tags
import GitLab.API.Todos
import GitLab.API.Users
import GitLab.API.Version
import GitLab.SystemHooks.GitLabSystemHooks
import GitLab.SystemHooks.Rules
import GitLab.SystemHooks.Types
import GitLab.Types
import Network.HTTP.Conduit
import Network.HTTP.Types.Status
import System.IO

-- | runs a GitLab action.
--
-- Internally, this creates a single 'Manager', whichs keeps track of
-- open connections for keep-alive and which is shared between
-- multiple threads and requests.
--
-- An example of its use is:
--
-- > projectsWithIssuesEnabled :: IO [Project]
-- > projectsWithIssuesEnabled =
-- >   runGitLab myConfig $ filter (issueEnabled . issues_enabled) <$> allProjects
-- >   where
-- >     myConfig = def
-- >         { url = "https://gitlab.example.com"
-- >         , authMethod = AuthMethodToken "my_access_token" }
-- >     issueEnabled Nothing = False
-- >     issueEnabled (Just b) = b
runGitLab :: GitLabServerConfig -> GitLab a -> IO (Either GitLabError a)
runGitLab cfg action = do
  liftIO $ hSetBuffering stdout LineBuffering
  let settings = mkManagerSettings def Nothing
  manager <- liftIO $ newManager settings
  runGitLabWithManager manager cfg action

-- | The same as 'runGitLab', except that it prompts for a GitLab
-- access token before running the GitLab action.
--
-- In this case you can just use 'def' with no
-- modification of the record field values, because these values will
-- be asked for at runtime:
--
-- > runGitLabPassPrompt def myGitLabProgram
runGitLabPassPrompt :: GitLabServerConfig -> GitLab a -> IO (Either GitLabError a)
runGitLabPassPrompt cfg action = do
  liftIO $ hSetBuffering stdout NoBuffering
  liftIO (putStr "Enter GitLab server URL\n> ")
  hostUrl <- getLine
  liftIO (putStr "Enter GitLab access token\n> ")
  pass <- getLine
  runGitLab (cfg {url = T.pack hostUrl, authMethod = AuthMethodToken (T.pack pass)}) action

-- | The same as 'runGitLab', except that it also takes a connection
-- manager as an argument.
runGitLabWithManager :: Manager -> GitLabServerConfig -> GitLab a -> IO (Either GitLabError a)
runGitLabWithManager manager cfg (GitLabT action) = do
  let withVersionCheck func = do
        -- test the token access
        let (GitLabT versionCheck) = gitlabVersion
        tokenTest <- runExceptT (runReaderT versionCheck (GitLabState cfg manager))
        case tokenTest of
          Left err -> return (Left err)
          Right (Left response) ->
            case responseStatus response of
              (Status 401 "Unauthorized") -> return $ Left (GitLabError "access token not accepted.")
              st -> return $ Left (GitLabError ("unexpected HTTP status: " <> T.pack (show st)))
          Right (Right _versionInfo) -> func
      goAhead = runExceptT (runReaderT action (GitLabState cfg manager))
  -- No version check without authentication because /version is not public.
  case authMethod cfg of
    AuthMethodNone -> goAhead
    _ -> withVersionCheck goAhead

-- | PATCHED, see PATCHES.md. The same as 'runGitLabWithManager', without the
-- token check.
--
-- 'runGitLabWithManager' asks the server for @\/version@ before every action it
-- runs, so a program that runs one action per record pays a second request for
-- every one it wanted -- twice the traffic, twice the wait behind a rate limit,
-- and twice the load on the server, to re-establish something that cannot have
-- changed. Use 'runGitLabWithManager' once at the start to check the token and
-- this for the rest.
runGitLabWithManagerUnchecked :: Manager -> GitLabServerConfig -> GitLab a -> IO (Either GitLabError a)
runGitLabWithManagerUnchecked manager cfg (GitLabT action) =
  runExceptT (runReaderT action (GitLabState cfg manager))

-- | Only useful for testing GitLab actions that lift IO actions with
-- liftIO. Cannot speak to a GitLab server. Only useful for the
-- gitlab-haskell tests.
runGitLabDbg :: GitLab a -> IO (Either GitLabError a)
runGitLabDbg (GitLabT action) = do
  liftIO $ hSetBuffering stdout LineBuffering
  manager <- liftIO $ newManager (mkManagerSettings def Nothing)
  let cfg = GitLabServerConfig {url = "", authMethod = AuthMethodToken "", retries = 1, delayBetweenRetries = 1, debugSystemHooks = Nothing}
  runExceptT (runReaderT action (GitLabState cfg manager))
