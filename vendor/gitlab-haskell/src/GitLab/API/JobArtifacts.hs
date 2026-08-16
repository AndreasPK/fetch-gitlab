{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Job artifacts
-- Description : Queries about and deletions of job artifacts
-- Copyright   : (c) Rob Stewart, Heriot-Watt University, 2025
-- License     : BSD3
-- Maintainer  : robstewart57@gmail.com
-- Stability   : stable
module GitLab.API.JobArtifacts
  ( -- * Delete all project artifacts
    deleteProjectArtifacts,
  )
where

import qualified Data.ByteString.Lazy as BSL
import Data.Text (Text)
import qualified Data.Text as T
import GitLab.Types
import GitLab.WebRequests.GitLabWebCalls
import Network.HTTP.Client

-- | Delete all job artifacts in a project.
--
-- Note from the documentation: "Requests to this endpoint set the expiry of all
-- job artifacts that can be deleted to the current time. The files are then
-- deleted from the system as part of the regular cleanup of expired job
-- artifacts. Job logs are never deleted. The regular cleanup occurs
-- asynchronously on a schedule, so there might be a short delay before
-- artifacts are deleted."
deleteProjectArtifacts ::
  -- | the project
  Project ->
  GitLab (Either (Response BSL.ByteString) (Maybe ()))
deleteProjectArtifacts prj = do
  gitlabDelete projAddr []
  where
    projAddr :: Text
    projAddr =
      "/projects/"
        <> T.pack (show (project_id prj))
        <> "/artifacts"
