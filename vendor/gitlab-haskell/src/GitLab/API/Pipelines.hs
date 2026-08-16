{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Pipelines
-- Description : Queries about project pipelines
-- Copyright   : (c) Rob Stewart, Heriot-Watt University, 2019
-- License     : BSD3
-- Maintainer  : robstewart57@gmail.com
-- Stability   : stable
module GitLab.API.Pipelines
  ( -- * List project pipelines
    pipelines,

    -- * Get a single pipeline
    pipeline,

    -- * Get a pipeline’s test report
    pipelineTestReport,

    -- * Create a new pipeline
    newPipeline,

    -- * Retry jobs in a pipeline
    retryPipeline,

    -- * Cancel a pipeline’s jobs
    cancelPipelineJobs,

    -- * Delete a pipeline
    deletePipeline,

    -- * Querying pipelines
    PipelineSearchAttrs (..),
    PipelineOrderBy (..),
    PipelineScope (..),
    PipelineStatus (..),
  )
where

import qualified Data.ByteString.Lazy as BSL
import Data.Default
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time.Clock
import GitLab.Types
import GitLab.WebRequests.GitLabWebCalls
import Network.HTTP.Client

-- | List pipelines in a project. Child pipelines are not included in the
-- results, but you can get child pipeline individually. Returns 'Nothing' if
-- access to the pipelines are forbidden e.g. for a project without any files.
pipelines ::
  -- | the project
  Project ->
  -- | pipeline filters
  PipelineSearchAttrs ->
  GitLab (Maybe [Pipeline])
pipelines p attrs = do
  result <- pipelines' (project_id p) attrs
  case result of
    Right ps -> return (Just ps)
    Left _err -> return Nothing -- perhaps throwError (GitLabError ..)

-- | returns the pipelines for a project given its project ID.
pipelines' ::
  -- | the project ID
  Int ->
  -- | pipeline filters
  PipelineSearchAttrs ->
  GitLab (Either (Response BSL.ByteString) [Pipeline])
pipelines' projectId attrs =
  gitlabGetMany
    addr
    (pipelineSearchAttrsParams attrs)
  where
    -- <> [("sort", Just "desc")] is most recent first

    addr =
      "/projects/"
        <> T.pack (show projectId)
        <> "/pipelines"

-- | Get one pipeline from a project.
pipeline ::
  -- | the project
  Project ->
  -- | 	The ID of a pipeline
  Int ->
  GitLab (Either (Response BSL.ByteString) (Maybe Pipeline))
pipeline prj pipelineId =
  gitlabGetOne
    addr
    []
  where
    addr =
      "/projects/"
        <> T.pack (show (project_id prj))
        <> "/pipelines/"
        <> T.pack (show pipelineId)

-- | get a pipeline’s test report. Since GitLab 13.0.
pipelineTestReport ::
  -- | the project
  Project ->
  -- | the pipeline ID
  Int ->
  GitLab (Either (Response BSL.ByteString) (Maybe TestReport))
pipelineTestReport prj pipelineId = do
  let urlPath =
        T.pack
          ( "/projects/"
              <> show (project_id prj)
              <> "/pipelines/"
              <> show pipelineId
              <> "/test_report"
          )
  gitlabGetOne urlPath []

-- | Create a new pipeline. Since GitLab 14.6.
newPipeline ::
  -- | the project
  Project ->
  -- | The branch or tag to run the pipeline on.
  Text ->
  GitLab (Either (Response BSL.ByteString) (Maybe Pipeline))
newPipeline prj ref = do
  gitlabPost
    pipelineAddr
    [("ref", Just (T.encodeUtf8 ref))]
  where
    pipelineAddr :: Text
    pipelineAddr =
      "/projects/"
        <> T.pack (show (project_id prj))
        <> "/pipeline"

-- | Retry a pipeline. Since GitLab 14.6.
retryPipeline ::
  -- | the project
  Project ->
  -- | The ID of a pipeline
  Int ->
  GitLab (Either (Response BSL.ByteString) (Maybe Pipeline))
retryPipeline prj pipelineId = do
  gitlabPost
    pipelineAddr
    []
  where
    pipelineAddr :: Text
    pipelineAddr =
      "/projects/"
        <> T.pack (show (project_id prj))
        <> "/pipelines/"
        <> T.pack (show pipelineId)
        <> "/retry"

-- | Cancel a pipeline's jobs.
cancelPipelineJobs ::
  -- | the project
  Project ->
  -- | The ID of a pipeline
  Int ->
  GitLab (Either (Response BSL.ByteString) (Maybe Pipeline))
cancelPipelineJobs prj pipelineId = do
  gitlabPost
    pipelineAddr
    []
  where
    pipelineAddr :: Text
    pipelineAddr =
      "/projects/"
        <> T.pack (show (project_id prj))
        <> "/pipelines/"
        <> T.pack (show pipelineId)
        <> "/cancel"

-- | Delete a pipline. Since GitLab 14.6.
deletePipeline ::
  -- | the project
  Project ->
  -- | The ID of a pipeline
  Int ->
  GitLab (Either (Response BSL.ByteString) (Maybe ()))
deletePipeline prj pipelineId = do
  gitlabDelete pipelineAddr []
  where
    pipelineAddr :: Text
    pipelineAddr =
      "/projects/"
        <> T.pack (show (project_id prj))
        <> "/pipelines/"
        <> T.pack (show pipelineId)

data PipelineSearchAttrs = PipelineSearchAttrs
  { -- | Return pipelines with the specified name.
    pipelineSearchFilter_name :: Maybe Text,
    -- | Order pipelines by id, status, ref, updated_at or user_id (default: id)
    pipelineSearchFilter_order_by :: Maybe PipelineOrderBy,
    -- | The ref of pipelines.
    pipelineSearchFilter_ref :: Maybe Text,
    -- | The scope of pipelines, one of: running, pending, finished, branches, tags.
    pipelineSearchFilter_scope :: Maybe PipelineScope,
    -- | The SHA of pipelines.
    pipelineSearchFilter_sha :: Maybe Text,
    -- | Sort pipelines in asc or desc order (default: desc).
    pipelineSearchFilter_sort :: Maybe SortBy,
    -- | The pipeline source.
    pipelineSearchFilter_source :: Maybe Text,
    -- | The status of pipelines, one of: created, waiting_for_resource,
    -- | preparing, pending, running, success, failed, canceled, skipped,
    -- | manual, scheduled.
    pipelineSearchFilter_status :: Maybe PipelineStatus,
    -- | Return pipelines updated after the specified date. Expected in ISO 8601
    -- | format (2019-03-15T08:00:00Z).
    pipelineSearchFilter_updated_after :: Maybe UTCTime,
    -- | Return pipelines updated before the specified date. Expected in ISO
    -- | 8601 format (2019-03-15T08:00:00Z).
    pipelineSearchFilter_updated_before :: Maybe UTCTime,
    -- | Return pipelines created after the specified date. Expected in ISO 8601
    -- | format (2019-03-15T08:00:00Z).
    pipelineSearchFilter_created_after :: Maybe UTCTime,
    -- | Return pipelines created before the specified date. Expected in ISO
    -- | 8601 format (2019-03-15T08:00:00Z).
    pipelineSearchFilter_created_before :: Maybe UTCTime,
    -- | The username of the user who triggered pipelines.
    pipelineSearchFilter_username :: Maybe Text,
    -- | Returns pipelines with invalid configurations.
    pipelineSearchFilter_yaml_errors :: Maybe Bool
  }

data PipelineOrderBy
  = PipelineOrderById
  | PipelineOrderByStatus
  | PipelineOrderByRef
  | PipelineOrderByUpdatedAt
  | PipelineOrderByUserId

instance Show PipelineOrderBy where
  show PipelineOrderById = "id"
  show PipelineOrderByStatus = "status"
  show PipelineOrderByRef = "ref"
  show PipelineOrderByUpdatedAt = "updated_at"
  show PipelineOrderByUserId = "user_id"

data PipelineScope
  = PipelineScopeRunning
  | PipelineScopePending
  | PipelineScopeFinished
  | PipelineScopeBranches
  | PipelineScopeTags

instance Show PipelineScope where
  show PipelineScopeRunning = "running"
  show PipelineScopePending = "pending"
  show PipelineScopeFinished = "finished"
  show PipelineScopeBranches = "branches"
  show PipelineScopeTags = "tags"

data PipelineStatus
  = PipelineCreated
  | PipelineWaitingForResource
  | PipelinePreparing
  | PipelinePending
  | PipelineRunning
  | PipelineSuccess
  | PipelineFailed
  | PipelineCanceled
  | PipelineSkipped
  | PipelineManual
  | PipelineScheduled

instance Show PipelineStatus where
  show PipelineCreated = "created"
  show PipelineWaitingForResource = "waiting_for_resource"
  show PipelinePreparing = "preparing"
  show PipelinePending = "pending"
  show PipelineRunning = "running"
  show PipelineSuccess = "success"
  show PipelineFailed = "failed"
  show PipelineCanceled = "canceled"
  show PipelineSkipped = "skipped"
  show PipelineManual = "manual"
  show PipelineScheduled = "scheduled"

pipelineSearchAttrsParams :: PipelineSearchAttrs -> [GitLabParam]
pipelineSearchAttrsParams filters =
  catMaybes
    [ (\t -> Just ("name", textToBS t)) =<< pipelineSearchFilter_name filters,
      (\x -> Just ("order_by", textToBS (T.pack (show x)))) =<< pipelineSearchFilter_order_by filters,
      (\t -> Just ("ref", textToBS t)) =<< pipelineSearchFilter_ref filters,
      (\x -> Just ("scope", textToBS (T.pack (show x)))) =<< pipelineSearchFilter_scope filters,
      (\t -> Just ("sha", textToBS t)) =<< pipelineSearchFilter_sha filters,
      (\x -> Just ("sort", textToBS (T.pack (show x)))) =<< pipelineSearchFilter_sort filters,
      (\t -> Just ("source", textToBS t)) =<< pipelineSearchFilter_source filters,
      (\x -> Just ("status", textToBS (T.pack (show x)))) =<< pipelineSearchFilter_status filters,
      (\d -> Just ("updated_after", textToBS (T.pack (show d)))) =<< pipelineSearchFilter_updated_after filters,
      (\d -> Just ("updated_before", textToBS (T.pack (show d)))) =<< pipelineSearchFilter_updated_before filters,
      (\d -> Just ("created_after", textToBS (T.pack (show d)))) =<< pipelineSearchFilter_created_after filters,
      (\d -> Just ("created_before", textToBS (T.pack (show d)))) =<< pipelineSearchFilter_created_before filters,
      (\t -> Just ("username", textToBS t)) =<< pipelineSearchFilter_username filters,
      (\b -> Just ("yaml_errors", textToBS (showBool b))) =<< pipelineSearchFilter_yaml_errors filters
    ]
  where
    textToBS = Just . T.encodeUtf8
    showBool :: Bool -> Text
    showBool True = "true"
    showBool False = "false"

-- | A default set of project searc filters where no project filters
-- are applied, thereby returning all projects.
instance Default PipelineSearchAttrs where
  def = PipelineSearchAttrs Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing
