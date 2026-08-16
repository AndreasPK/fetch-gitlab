{-# LANGUAGE OverloadedStrings #-}

-- Standalone reproducer for two related bugs in gitlab-haskell 1.4.0.0.
--
-- Bug A (field type): GitLab returns @"source_project_id": null@ for a
-- merge request whose source project (fork) has been deleted, but
-- 'GitLab.Types.MergeRequest' declares
-- @merge_request_source_project_id :: Int@ (src/GitLab/Types.hs:962), so
-- 'FromJSON' fails on any such merge request.  A live example is
-- https://gitlab.haskell.org/ghc/ghc/-/merge_requests/16018
-- (@target_project_id@ has the same type and is presumably the same
-- latent issue).
--
-- Bug B (swallowed decode errors): the library reports decode failures as
-- successes.  For single results, @parseOne@ in
-- GitLab.WebRequests.GitLabWebCalls maps any parse error to 'Nothing', so
-- an existing MR is indistinguishable from an absent one.  For paginated
-- results, @gitlabHTTPMany@ prints the parse error to stderr and returns
-- @Right accum@, so one undecodable record silently discards its whole
-- page (up to 100 records) and every page after it, and the caller sees
-- an ordinary success with a truncated list.
--
-- Usage:
--
--   cabal run repro              -- steps 1+2: fetch ghc/ghc !16018 (2 requests)
--   cabal run repro -- --list    -- also step 3: silent list truncation (~7 requests)
--   cabal run repro -- --offline -- step 1 only, against fixtures/mr-16018.json
--
-- Optionally set GITLAB_TOKEN to a gitlab.haskell.org read token to
-- authenticate the requests (helps against anonymous rate limiting).
--
-- Exit code 1 if a bug reproduced, 0 if everything behaved.

module Main (main) where

import Control.Monad (when)
import Data.Aeson (Value (..), decode, eitherDecode, encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSL8
import Data.Default (def)
import Data.IORef
import qualified Data.Text as T
import Data.Time.Format.ISO8601 (iso8601ParseM)
import GitLab (runGitLab)
import GitLab.API.MergeRequests
  ( MergeProjectAttrs (..),
    mergeRequest,
    mergeRequestsWith,
    mrAttrs,
  )
import GitLab.Types
import Network.HTTP.Conduit (responseStatus)
import Network.HTTP.Simple
  ( getResponseBody,
    httpLBS,
    parseRequest,
    setRequestHeader,
  )
import Network.HTTP.Types.Status (statusCode)
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  args <- getArgs
  mtok <- lookupEnv "GITLAB_TOKEN"
  bugRef <- newIORef False

  if "--offline" `elem` args
    then step1 bugRef =<< BSL.readFile "fixtures/mr-16018.json"
    else do
      let cfg = config mtok
      step1 bugRef =<< fetchRaw mtok
      step2 bugRef cfg
      when ("--list" `elem` args) (step3 bugRef cfg)

  reproduced <- readIORef bugRef
  if reproduced
    then putStrLn "\n*** bug(s) reproduced ***" >> exitFailure
    else putStrLn "\nno bugs reproduced" >> exitSuccess

config :: Maybe String -> GitLabServerConfig
config mtok =
  def
    { url = "https://gitlab.haskell.org",
      authMethod = maybe AuthMethodNone (AuthMethodToken . T.pack) mtok
    }

-- ghc/ghc has project id 1 on gitlab.haskell.org.  'mergeRequest' and
-- 'mergeRequestsWith' only use 'project_id', and the by-id variants
-- (mergeRequest', mergeRequestsWith') are not exported, so build a minimal
-- 'Project' through its FromJSON instance.
ghcProject :: Project
ghcProject =
  case eitherDecode
    "{\"id\":1,\"name\":\"GHC\",\"name_with_namespace\":\"Glasgow Haskell Compiler / GHC\",\
    \\"path\":\"ghc\",\"path_with_namespace\":\"ghc/ghc\",\
    \\"web_url\":\"https://gitlab.haskell.org/ghc/ghc\"}" of
    Right p -> p
    Left err -> error ("minimal Project JSON no longer decodes: " <> err)

-- Fetch the raw JSON of ghc/ghc !16018.  This uses http-conduit directly
-- because gitlab-haskell's raw-response function lives in an unexposed
-- module; the bytes are exactly what the library would try to decode.
fetchRaw :: Maybe String -> IO BSL.ByteString
fetchRaw mtok = do
  req <- parseRequest "https://gitlab.haskell.org/api/v4/projects/1/merge_requests/16018"
  let req' =
        setRequestHeader "User-Agent" ["gitlab-haskell-repro"] $
          maybe req (\t -> setRequestHeader "PRIVATE-TOKEN" [BS8.pack t] req) mtok
  getResponseBody <$> httpLBS req'

step1 :: IORef Bool -> BSL.ByteString -> IO ()
step1 bugRef body = do
  putStrLn "== 1. decode the JSON of ghc/ghc !16018 as MergeRequest =="
  case decode body of
    Just (Object o) ->
      putStrLn $
        "   response has \"source_project_id\": "
          <> maybe "<missing>" (BSL8.unpack . encode) (KM.lookup "source_project_id" o)
    _ -> putStrLn "   (response is not a JSON object - unexpected, rate limited?)"
  case eitherDecode body :: Either String MergeRequest of
    Right mr ->
      putStrLn $ "   decoded OK: iid " <> show (merge_request_iid mr)
    Left err -> do
      putStrLn $ "   BUG A (field type): " <> err
      writeIORef bugRef True

step2 :: IORef Bool -> GitLabServerConfig -> IO ()
step2 bugRef cfg = do
  putStrLn "== 2. fetch the same MR through the typed API (mergeRequest) =="
  result <- runGitLab cfg (mergeRequest ghcProject 16018)
  case result of
    Left err -> putStrLn $ "   GitLabError: " <> show err
    Right (Left resp) ->
      putStrLn $ "   HTTP error " <> show (statusCode (responseStatus resp))
    Right (Right (Just mr)) ->
      putStrLn $ "   got the MR: iid " <> show (merge_request_iid mr)
    Right (Right Nothing) -> do
      putStrLn "   BUG B (swallowed error): returned (Right Nothing), i.e. the MR"
      putStrLn "   does not exist - parseOne discarded the JSON parse error."
      writeIORef bugRef True

step3 :: IORef Bool -> GitLabServerConfig -> IO ()
step3 bugRef cfg = do
  putStrLn "== 3. list ghc/ghc MRs updated after 2025-08-16 (contains !16018) =="
  putStrLn "   (lines tagged [gitlab-haskell] are the library writing to stderr;"
  putStrLn "    the caller has no programmatic access to that error)"
  since <- iso8601ParseM "2025-08-16T09:04:49Z"
  result <-
    runGitLab cfg $
      mergeRequestsWith ghcProject mrAttrs {mr_attr_updated_after = Just since}
  case result of
    Left err -> putStrLn $ "   GitLabError: " <> show err
    Right mrs -> do
      putStrLn $ "   returned as success: " <> show (length mrs) <> " merge requests"
      if 16018 `elem` map merge_request_iid mrs
        then putStrLn "   !16018 is present - decoding must have been fixed"
        else do
          putStrLn "   BUG B (silent truncation): !16018 matches this query, but the"
          putStrLn "   page containing it failed to decode, so that page and all later"
          putStrLn "   pages were dropped - yet the call reported success.  At the"
          putStrLn "   time of writing this drops 1853 of 2353 matching MRs (79%)."
          writeIORef bugRef True
