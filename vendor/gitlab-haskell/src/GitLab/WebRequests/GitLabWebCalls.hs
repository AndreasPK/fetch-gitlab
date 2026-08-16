{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | internal module to support modules in GitLab.API
module GitLab.WebRequests.GitLabWebCalls
  ( GitLabParam,
    gitlabGetOne,
    gitlabGetMany,
    gitlabGetPage,
    gitlabPost,
    gitlabPut,
    gitlabDelete,
    gitlabUnsafe,
    gitlabGetByteStringResponse,
    responseErrorText,
    httpResponseError,
  )
where

import Control.Concurrent (threadDelay)
import qualified Control.Exception as Exception
import Control.Monad.Except
import Control.Monad.IO.Class
import qualified Control.Monad.Reader as MR
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Maybe (isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import GitLab.Types
import Network.HTTP.Conduit
import Network.HTTP.Types.Status
import Network.HTTP.Types.URI
import System.IO (hPutStrLn, stderr)
import Text.Read

newtype GitLabException = GitLabException String
  deriving (Eq, Show)

instance Exception.Exception GitLabException

type GitLabParam = (BS.ByteString, Maybe BS.ByteString)

gitlabGetOne ::
  (FromJSON a) =>
  -- | the URL to post to
  Text ->
  -- | the data to post
  [GitLabParam] ->
  GitLab (Either (Response BSL.ByteString) (Maybe a))
gitlabGetOne urlPath params =
  request
  where
    request =
      gitlabHTTPOne
        "GET"
        "application/x-www-form-urlencoded"
        urlPath
        params
        []

gitlabGetMany ::
  (FromJSON a) =>
  -- | the URL to post to
  Text ->
  -- | the data to post
  [GitLabParam] ->
  GitLab (Either (Response BSL.ByteString) [a])
gitlabGetMany urlPath params =
  gitlabHTTPMany
    "GET"
    "application/x-www-form-urlencoded"
    urlPath
    params
    []

-- | PATCHED, see PATCHES.md. One page of a collection, rather than all of it.
--
-- 'gitlabGetMany' pages to the end of a collection before it returns anything,
-- which leaves a caller with no way to see progress, to save what has arrived
-- so far, or to choose where the next page starts. This returns a single page
-- and lets the caller decide what to do next.
--
-- A short page means there was nothing more to return, which is how a caller
-- knows to stop.
gitlabGetPage ::
  (FromJSON a) =>
  -- | the URL to get
  Text ->
  -- | the URL parameters
  [GitLabParam] ->
  -- | how many records to ask for; GitLab caps this at 100
  Int ->
  GitLab (Either (Response BSL.ByteString) [a])
gitlabGetPage urlPath params perPage = do
  response <-
    gitlabHTTP
      "GET"
      "application/x-www-form-urlencoded"
      urlPath
      (params <> [("per_page", Just (showBS perPage)), ("page", Just "1")])
      []
  if successStatus (responseStatus response)
    then Right <$> decodePage urlPath 1 (responseBody response)
    else return (Left response)

gitlabPost ::
  (FromJSON a) =>
  -- | the URL to post to
  Text ->
  -- | the data to post
  [GitLabParam] ->
  GitLab (Either (Response BSL.ByteString) (Maybe a))
gitlabPost urlPath params = do
  request
  where
    request =
      gitlabHTTPOne
        "POST"
        "application/x-www-form-urlencoded"
        urlPath
        []
        params

gitlabPut ::
  (FromJSON a) =>
  -- | the URL to post to
  Text ->
  -- | the data to post
  [GitLabParam] ->
  GitLab (Either (Response BSL.ByteString) (Maybe a))
gitlabPut urlPath params = do
  request
  where
    request =
      gitlabHTTPOne
        "PUT"
        "application/x-www-form-urlencoded"
        urlPath
        []
        params

gitlabDelete ::
  (FromJSON a) =>
  -- | the URL to post to
  Text ->
  -- | the data to post
  [GitLabParam] ->
  GitLab (Either (Response BSL.ByteString) (Maybe a))
gitlabDelete urlPath params = do
  request
  where
    request =
      gitlabHTTPOne
        "DELETE"
        "application/x-www-form-urlencoded"
        urlPath
        []
        params

-- | Assumes that HTTP error code responses, e.g. 404, 409, won't be
-- returned as (Left response) value.
gitlabUnsafe :: GitLab (Either a (Maybe b)) -> GitLab b
gitlabUnsafe query = do
  result <- query
  case result of
    Left _err -> throwError (GitLabError "gitlabUnsafe error")
    Right Nothing -> throwError (GitLabError "gitlabUnsafe error")
    Right (Just x) -> return x

-- | Lower level query that returns the raw bytestring response from a
-- GitLab HTTP query. Useful for downloading project archives files.
gitlabGetByteStringResponse ::
  -- | the URL to post to
  Text ->
  -- | the data to post
  [GitLabParam] ->
  GitLab (Response BSL.ByteString)
gitlabGetByteStringResponse urlPath params =
  request
  where
    request =
      gitlabHTTP
        "GET"
        "application/x-www-form-urlencoded"
        urlPath
        params
        []

-- | Format a failed HTTP response into a human-readable error message.
responseErrorText :: Response payload -> T.Text
responseErrorText resp =
  "HTTP "
    <> T.pack (show (statusCode (responseStatus resp)))
    <> " "
    <> T.decodeUtf8 (statusMessage (responseStatus resp))

-- | Build a structured 'GitLabHttpError' from a failed HTTP response, tagging
-- it with the API operation that produced it (e.g. @\"userEvents\"@).
--
-- The response status and headers are retained, so callers can inspect them
-- (for example, to honour rate-limit headers such as @Retry-After@).
httpResponseError :: Text -> Response payload -> GitLabError
httpResponseError context resp =
  GitLabHttpError
    HttpResponseError
      { httpErrorContext = context,
        httpErrorStatus = responseStatus resp,
        httpErrorHeaders = responseHeaders resp
      }

---------------------
-- internal functions

gitlabHTTP ::
  -- | HTTP method (PUT, POST, DELETE, GET)
  BS.ByteString ->
  -- | Content type (content-type)
  BS.ByteString ->
  -- | the URL
  Text ->
  -- | the URL parameters for GET calls
  [GitLabParam] ->
  -- | the content paramters for POST, PUT and DELETE calls
  [GitLabParam] ->
  GitLab (Response BSL.ByteString)
gitlabHTTP httpMethod contentType urlPath urlParams contentParams = do
  cfg <- MR.asks serverCfg
  manager <- MR.asks httpManager
  let url' = url cfg <> "/api/v4" <> urlPath <> T.decodeUtf8 (renderQuery True urlParams)
  let authHeaders = case authMethod cfg of
        AuthMethodNone -> []
        AuthMethodToken t -> [("PRIVATE-TOKEN", T.encodeUtf8 t)]
        AuthMethodOAuth t -> [("Authorization", "Bearer " <> T.encodeUtf8 t)]
  let request' = parseRequest_ (T.unpack url')
      request =
        request'
          { method = httpMethod,
            requestHeaders =
              authHeaders
                <> [ ("content-type", contentType)
                   ],
            requestBody = RequestBodyBS (renderQuery False contentParams)
          }
  liftIO $ tryGitLab 0 request (retries cfg) (delayBetweenRetries cfg) manager Nothing

gitlabHTTPOne ::
  (FromJSON a) =>
  -- | HTTP method (PUT, POST, DELETE, GET)
  BS.ByteString ->
  -- | Content type (content-type)
  BS.ByteString ->
  -- | the URL
  Text ->
  -- | the URL query data for GET calls
  [GitLabParam] ->
  -- | the content parameters for POST, PUT and DELETE calls
  [GitLabParam] ->
  GitLab
    (Either (Response BSL.ByteString) (Maybe a))
gitlabHTTPOne httpMethod contentType urlPath urlParams contentParams = do
  response <-
    gitlabHTTP
      httpMethod
      contentType
      urlPath
      urlParams
      contentParams
  if successStatus (responseStatus response)
    -- PATCHED, see PATCHES.md. 'parseOne' threw the decode error away, so a
    -- result the library could not read was indistinguishable from one the
    -- server does not have. A caller then reports "no such project" for a
    -- server that answered with something else entirely, which is a long way
    -- from the truth and sends whoever reads it after the wrong problem.
    --
    -- 'Nothing' is now only ever "the server does not have this". A body that
    -- cannot be read is an error, and a genuine absence is a 404, which is not
    -- a success status and so returns Left above.
    then case eitherDecode (responseBody response) of
      Left decodeErr -> throwError (GitLabError (notJson urlPath decodeErr (responseBody response)))
      Right x -> return (Right (Just x))
    else return (Left response)

gitlabHTTPMany ::
  (FromJSON a) =>
  -- | HTTP method (PUT, POST, DELETE, GET)
  BS.ByteString ->
  -- | Content type (content-type)
  BS.ByteString ->
  -- | the URL
  Text ->
  -- | the URL query data for GET calls
  [GitLabParam] ->
  -- | the content parameters for POST, PUT and DELETE calls
  [GitLabParam] ->
  GitLab
    (Either (Response BSL.ByteString) [a])
gitlabHTTPMany httpMethod contentType urlPath urlParams contentParams = do
  go 1 []
  where
    go :: (FromJSON a) => Int -> [a] -> GitLab (Either (Response BSL.ByteString) [a])
    go pageNum accum = do
      response <-
        gitlabHTTP
          httpMethod
          contentType
          urlPath
          (urlParams <> [("per_page", Just "100"), ("page", Just (showBS pageNum))])
          contentParams
      if successStatus (responseStatus response)
        then do
          accum' <- (accum <>) <$> decodePage urlPath pageNum (responseBody response)
          if hasNextPage response
            then go (pageNum + 1) accum'
            else return (Right accum')
        else return (Left response)

-- | PATCHED, see PATCHES.md. One page of a collection, decoded a record at a
-- time.
--
-- Upstream decoded the page as a whole and, when that failed, wrote to stderr
-- and returned the pages gathered so far as a success -- abandoning every
-- remaining page. One record the library mistypes therefore silently lost the
-- rest of the collection, and the caller could not tell.
--
-- The page is now taken apart first and decoded a record at a time, so a
-- record that cannot be read costs that record and nothing else, and paging
-- carries on to the end.
decodePage :: (FromJSON a) => Text -> Int -> BSL.ByteString -> GitLab [a]
decodePage urlPath pageNum body =
  case eitherDecode body :: Either String [Value] of
    -- Not a JSON array at all, so there are no records to salvage. Upstream
    -- returned success here too; a caller that cannot see the difference
    -- between "no more results" and "we gave up" cannot do anything sensible,
    -- so this is now an error.
    Left decodeErr ->
      throwError . GitLabError $
        notJson (urlPath <> T.pack (" (page " <> show pageNum <> ")")) decodeErr body
    Right values -> concat <$> mapM decodeRecord values
  where
    -- One record of a page. A failure is reported and skipped rather than
    -- ending the collection; the empty list is what makes it a skip.
    decodeRecord value =
      case fromJSON value of
        Success x -> return [x]
        Error decodeErr -> do
          liftIO $
            hPutStrLn stderr $
              "[gitlab-haskell] skipping one record of "
                <> T.unpack urlPath
                <> " (page "
                <> show pageNum
                <> "): "
                <> decodeErr
          liftIO $
            hPutStrLn stderr $
              "[gitlab-haskell] the record that was skipped: "
                <> show (BSL.take 2000 (encode value))
          return []

showBS :: (Show a) => a -> BS.ByteString
showBS = T.encodeUtf8 . T.pack . show

-- | PATCHED, see PATCHES.md. Say what came back instead of JSON.
--
-- The case worth naming is an anti-bot interstitial. Those are served with a
-- 200 and an HTML body, so every check short of parsing says the request
-- succeeded, and the caller is left reporting something like "no such project"
-- for a server that never showed it one. Saying "this was HTML" is the
-- difference between a minute and an hour of looking in the wrong place.
notJson :: Text -> String -> BSL.ByteString -> Text
notJson urlPath decodeErr body =
  T.concat
    [ "the server answered "
    , urlPath
    , " with "
    , description
    , " rather than JSON: "
    , T.pack decodeErr
    , "; the response began "
    , T.pack (show (BSL.take 300 body))
    ]
  where
    description
      | isChallenge = "an anti-bot interstitial (the request never reached the API)"
      | looksHtml = "an HTML page"
      -- The body is JSON, so the server did answer; it is this library's idea
      -- of the shape that is wrong. Saying "rather than JSON" about a JSON
      -- body would send the reader looking for a network problem that is not
      -- there.
      | isJson = "JSON that does not have the shape this library expects"
      | otherwise = "something"

    isJson = isJust (decode body :: Maybe Value)

    -- Served with a 200, so the status says nothing about it; the body is all
    -- there is to go on.
    isChallenge =
      looksHtml
        && any
          (`T.isInfixOf` beginning)
          ["not a bot", "anubis", "checking your browser", "captcha"]

    looksHtml = any (`T.isPrefixOf` T.stripStart beginning) ["<!doctype", "<html"]

    beginning = T.toLower (T.decodeUtf8Lenient (BSL.toStrict (BSL.take 4000 body)))

hasNextPage :: Response a -> Bool
hasNextPage resp =
  let hdrs = responseHeaders resp
   in findPages hdrs
  where
    findPages [] = False
    findPages (("X-Next-Page", bs) : _) = isJust $ readNP bs
    findPages (_ : xs) = findPages xs
    readNP :: BS.ByteString -> Maybe Int
    readNP bs = readMaybe (T.unpack (T.decodeUtf8 bs))

successStatus :: Status -> Bool
successStatus (Status n _msg) =
  n >= 200 && n <= 226

tryGitLab ::
  -- | the current retry count
  Int ->
  -- | the GitLab request
  Request ->
  -- | maximum number of retries permitted
  Int ->
  -- | delay between retries in seconds
  Int ->
  -- | HTTP manager
  Manager ->
  -- | the exception to report if maximum retries met
  Maybe HttpException ->
  IO (Response BSL.ByteString)
tryGitLab i request maxRetries delaySeconds manager lastException
  | i == maxRetries = error (show lastException)
  | otherwise =
      httpLbs request manager
        `Exception.catch` \ex -> threadDelay delaySeconds >> tryGitLab (i + 1) request maxRetries delaySeconds manager (Just ex)

-- PATCHED, see PATCHES.md. 'parseOne' used to live here, discarding the decode
-- error and returning Nothing. 'gitlabHTTPOne' now decodes for itself so that
-- it can say why a body could not be read rather than calling it absent, which
-- leaves nothing for this to do. It was not exported.
