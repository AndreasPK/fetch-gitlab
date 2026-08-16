{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}

-- |
-- Module      : GitLab.API.Events
-- Description : Queries for GitLab Events API
-- Copyright   : (c) Rob Stewart, Heriot-Watt University, 2019
-- License     : BSD3
-- Maintainer  : robstewart57@gmail.com
-- Stability   : stable
--
-- See <https://docs.gitlab.com/ee/api/events.html>
module GitLab.API.Events
  ( -- * Authenticated user events
    currentUserEvents,

    -- * User events
    userEvents,
    userEvents',

    -- * Project events
    projectEvents,
    projectEvents',

    -- * Group events
    groupEvents,
    groupEvents',

    -- * Filter attributes
    EventFilterAttrs (..),
  )
where

import Control.Monad.Except
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Default
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Time.Clock
import Data.Time.Format.ISO8601
import GitLab.Types
import GitLab.WebRequests.GitLabWebCalls
import Network.HTTP.Client

-- | Filter attributes for event queries.
--
-- Use 'defaultEventFilters' as a starting point and override fields as needed.
data EventFilterAttrs = EventFilterAttrs
  { -- | Filter by action name (e.g. 'ANOpened', 'ANMerged', 'ANCommentedOn').
    eventFilter_action :: Maybe EventActionName,
    -- | Filter by target type (e.g. 'ETTIssue', 'ETTMergeRequest').
    eventFilter_target_type :: Maybe EventTargetType,
    -- | Return events created before this date (ISO 8601).
    eventFilter_before :: Maybe UTCTime,
    -- | Return events created after this date (ISO 8601).
    eventFilter_after :: Maybe UTCTime,
    -- | Sort order: 'Asc' or 'Desc'.
    eventFilter_sort :: Maybe SortBy
  }

-- | Default event filters: no filtering applied.
instance Default EventFilterAttrs where
  def = EventFilterAttrs Nothing Nothing Nothing Nothing Nothing

-- | Get events for the currently authenticated user.
--
-- Calls @GET \/events@
currentUserEvents ::
  -- | filter attributes
  EventFilterAttrs ->
  GitLab [Event]
currentUserEvents attrs = do
  result <- gitlabGetMany "/events" (eventFilters attrs)
  case result of
    Left er -> throwError (httpResponseError "currentUserEvents" er)
    Right xs -> return xs

-- | Get events for a specific user.
--
-- Calls @GET \/users\/:id\/events@
userEvents ::
  -- | the user
  User ->
  -- | filter attributes
  EventFilterAttrs ->
  GitLab [Event]
userEvents usr attrs = do
  result <- userEvents' (user_id usr) attrs
  case result of
    Left er -> throwError (httpResponseError "userEvents" er)
    Right xs -> return xs

-- | Get events for a specific user by ID.
--
-- Calls @GET \/users\/:id\/events@
userEvents' ::
  -- | user ID
  Int ->
  -- | filter attributes
  EventFilterAttrs ->
  GitLab (Either (Response BSL.ByteString) [Event])
userEvents' userId attrs =
  gitlabGetMany urlPath (eventFilters attrs)
  where
    urlPath =
      T.pack $
        "/users/"
          <> show userId
          <> "/events"

-- | Get events for a project.
--
-- Calls @GET \/projects\/:id\/events@
projectEvents ::
  -- | the project
  Project ->
  -- | filter attributes
  EventFilterAttrs ->
  GitLab [Event]
projectEvents proj attrs = do
  result <- projectEvents' (project_id proj) attrs
  case result of
    Left er -> throwError (httpResponseError "projectEvents" er)
    Right xs -> return xs

-- | Get events for a project by ID.
--
-- Calls @GET \/projects\/:id\/events@
projectEvents' ::
  -- | project ID
  Int ->
  -- | filter attributes
  EventFilterAttrs ->
  GitLab (Either (Response BSL.ByteString) [Event])
projectEvents' projectId attrs =
  gitlabGetMany urlPath (eventFilters attrs)
  where
    urlPath =
      T.pack $
        "/projects/"
          <> show projectId
          <> "/events"

-- | Get events for a group.
--
-- Calls @GET \/groups\/:id\/events@
groupEvents ::
  -- | the group
  Group ->
  -- | filter attributes
  EventFilterAttrs ->
  GitLab [Event]
groupEvents grp attrs = do
  result <- groupEvents' (group_id grp) attrs
  case result of
    Left er -> throwError (httpResponseError "groupEvents" er)
    Right xs -> return xs

-- | Get events for a group by ID.
--
-- Calls @GET \/groups\/:id\/events@
groupEvents' ::
  -- | group ID
  Int ->
  -- | filter attributes
  EventFilterAttrs ->
  GitLab (Either (Response BSL.ByteString) [Event])
groupEvents' groupId attrs =
  gitlabGetMany urlPath (eventFilters attrs)
  where
    urlPath =
      T.pack $
        "/groups/"
          <> show groupId
          <> "/events"

-- Internal helpers

eventFilters :: EventFilterAttrs -> [GitLabParam]
eventFilters attrs =
  catMaybes
    [ (\a -> Just ("action", encodeText (actionParam a))) =<< eventFilter_action attrs,
      (\t -> Just ("target_type", encodeText (targetTypeParam t))) =<< eventFilter_target_type attrs,
      (\d -> Just ("before", encodeText (showTime d))) =<< eventFilter_before attrs,
      (\d -> Just ("after", encodeText (showTime d))) =<< eventFilter_after attrs,
      (\s -> Just ("sort", encodeText (T.pack (show s)))) =<< eventFilter_sort attrs
    ]
  where
    encodeText :: Text -> Maybe BS.ByteString
    encodeText = Just . T.encodeUtf8
    showTime :: UTCTime -> Text
    showTime = T.pack . iso8601Show

-- | Convert 'EventActionName' to the string value expected by the
-- GitLab filter query parameter.
actionParam :: EventActionName -> Text
actionParam ANOpened = "opened"
actionParam ANClosed = "closed"
actionParam ANPushed = "pushed"
actionParam ANCommentedOn = "commented"
actionParam ANMerged = "merged"
actionParam ANCreated = "created"
actionParam ANUpdated = "updated"
actionParam ANApproved = "approved"
actionParam ANReopened = "reopened"
actionParam ANLeft = "left"
actionParam ANJoined = "joined"
actionParam ANDestroyed = "destroyed"
actionParam ANExpired = "expired"
actionParam ANDeleted = "deleted"
actionParam ANAccepted = "accepted"
actionParam (ANOther t) = t

-- | Convert 'EventTargetType' to the lowercase string value expected
-- by the GitLab filter query parameter.
targetTypeParam :: EventTargetType -> Text
targetTypeParam ETTIssue = "issue"
targetTypeParam ETTMilestone = "milestone"
targetTypeParam ETTMergeRequest = "merge_request"
targetTypeParam ETTNote = "note"
targetTypeParam ETTProject = "project"
targetTypeParam ETTSnippet = "snippet"
targetTypeParam ETTUser = "user"
targetTypeParam ETTWikiPage = "wiki_page"
targetTypeParam ETTDesign = "design"
targetTypeParam (ETTOther t) = t
