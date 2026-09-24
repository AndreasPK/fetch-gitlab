{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- | Fetching issues and merge requests from a GitLab server.

Fetching is incremental: the store is asked for the newest @updated_at@ it
holds and only records modified since then are requested, and then for which
discussions it is still missing. A run holds a page of records and the plan
for the notes phase, never the store; what it learns it writes out at once.
-}
module FetchGitLab.Fetch (
    run,
    serverConfig,
    requestsPerSecond,
    readToken,
    waitOutChallenge,
    challengeWaits,
    challengeDetail,
    orChallenge,
    addUserAgent,
    userAgent,
    pipelineOwner,
    pipelineIsCurrent,
    usableSummary,
) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (forM, forM_, when)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson (Value (..), object)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.Types as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as BL
import Data.Char (isDigit)
import Data.Default (def)
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, mapMaybe)
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8Lenient, encodeUtf8)
import qualified Data.Text.IO as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Version (showVersion)
import Network.HTTP.Client (
    Manager,
    Request,
    Response,
    requestHeaders,
    responseBody,
    responseStatus,
 )
import Network.HTTP.Client.Internal (Manager (..))
import Network.HTTP.Types.Header (hUserAgent)
import Network.HTTP.Types.Status (Status, statusCode, statusIsSuccessful)
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO.Error (ioeGetErrorString, isDoesNotExistError, isPermissionError)

import GitLab (GitLab, runGitLabWithManager, runGitLabWithManagerUnchecked)
import GitLab.API.Issues (IssueFilterAttrs (..), projectIssuesPage)
import GitLab.API.MergeRequests (MergeProjectAttrs (..), mergeRequestsWithPage, mrAttrs)
import GitLab.API.Notes (issueNotes, mergeRequestNotes)
import GitLab.API.Projects (projectWithPathAndName)
import GitLab.Types (
    AuthMethod (..),
    GitLabError (..),
    GitLabServerConfig (..),
    Issue,
    MergeRequest,
    Note,
    OrderBy (..),
    Project,
    SortBy (..),
    project_id,
 )
import GitLab.WebRequests.GitLabWebCalls (gitlabGetByteStringResponse, gitlabGetMany, gitlabGetOne)

import Log (
    LogLevel (..),
    LogT,
    MonadLog,
    getLoggerIO,
    logAttention_,
    logInfo_,
    logTrace_,
    runLogT,
 )

import FetchGitLab.JobLog (stripControlChars)
import FetchGitLab.Lock (
    LockBusy (..),
    LockInfo (..),
    lockPath,
    withStoreLocks,
 )
import FetchGitLab.Logging (withFetchLogger)
import FetchGitLab.Options (Options (..), PipelineRequest (..), tokenFile)
import FetchGitLab.RateLimit (newRateLimiter, rateLimitedManager)
import FetchGitLab.Since (Since, resolveSince)
import FetchGitLab.Store (Record (..))
import FetchGitLab.Store.Backend (optionsSpec, specPaths, withStore)
import FetchGitLab.Store.Class (PipelineState (..), SomeStore (..), StoreBackend (..), describePurged)
import Paths_fetch_gitlab (version)

{- | How many requests per second we allow ourselves.

Two was enough to draw gitlab.haskell.org's anti-bot check repeatedly during
a long discussion phase, so this backs off to below it. The check clears on
its own after a few minutes and the requests it refuses are left pending
rather than lost, so tripping it costs time rather than data — but a run
that does not trip it is a run that does not have to make that good.
-}
requestsPerSecond :: Double
requestsPerSecond = 1.5

{- | How many records to ask for in one page.

This is the batch the store is written in, so it is also how often a run
reports progress. GitLab caps it at 100 and a page is a single request, so
asking for less would not report anything sooner -- it would only take more
requests to fetch the same collection.
-}
recordsPerPage :: Int
recordsPerPage = 100

{- | Read the access token, which lives in a file so it does not have to be
passed on the command line where every process can see it.

Returns what is wrong rather than throwing. A mistyped @--token@ path is an
ordinary user error and deserves a line of explanation, not a backtrace out
of 'T.readFile'. An empty file is rejected here too, since it would
otherwise surface much later as an unauthorised response.
-}
readToken :: FilePath -> IO (Either Text Text)
readToken path = do
    contents <- try (T.readFile path)
    pure $ case contents of
        Left e
            | isDoesNotExistError e -> Left ("no such file: " <> quoted)
            | isPermissionError e -> Left ("not readable: " <> quoted)
            | otherwise -> Left (quoted <> ": " <> T.pack (ioeGetErrorString e))
        Right raw
            | T.null token -> Left ("no token in " <> quoted <> ", the file is empty")
            | otherwise -> Right token
          where
            token = T.strip raw
  where
    quoted = T.pack (show path)

-- | Server configuration for a server and an already read token.
serverConfig :: Options -> Text -> GitLabServerConfig
serverConfig opts token =
    GitLabServerConfig
        { url = optServerUrl opts
        , authMethod = AuthMethodToken token
        , retries = 5
        , delayBetweenRetries = 1
        , debugSystemHooks = Nothing
        }

{- | Fetch tickets and merge requests and write them into the store.

The store is locked for the duration, and the lock is about time rather than
correctness: two runs against one store cannot corrupt it — every write
states one thing the run just learned, in its own transaction — but they
would spend hours fetching the same project twice and double the request
rate against the one token that is allowed to make them. The second run is
turned away and told who is in the way; see "FetchGitLab.Lock".
-}
run :: Options -> IO ()
run opts = withFetchLogger (optLogFile opts) terminalLevel $ \logger level -> do
    let runLog :: LogT IO a -> IO a
        runLog = runLogT "fetch-gitlab" logger level
    spec <- optionsSpec opts
    let paths = specPaths spec
    -- The default location is under the home directory and will not exist on a
    -- first run. The lock files are created in there, so this comes first.
    mapM_ (createDirectoryIfMissing True . takeDirectory) paths
    locked <-
        withStoreLocks paths . withStore spec $ \(SomeStore store) ->
            runLog $ do
                logInfo_ $ "Store: " <> storeName store <> " at " <> storeLocation store
                fetch store
    case locked of
        Right () -> pure ()
        Left busy -> runLog $ do
            logAttention_ $
                "Another fetch-gitlab is already running against "
                    <> T.pack (busyStore busy)
                    <> holder busy
            logAttention_ $
                "Its lock is held on "
                    <> T.pack (lockPath (busyStore busy))
                    <> "; point --tickets/--mrs/--db at a separate store to work alongside it"
            liftIO exitFailure
  where
    -- The lock is only reported as held while its owner is alive, so this
    -- names a process that really is running.
    holder busy = case busyHolder busy of
        Nothing -> ""
        Just i -> ": pid " <> tshow (lockPid i) <> ", started " <> tshow (lockStartedAt i)

    fetch :: (StoreBackend b) => b -> LogT IO ()
    fetch store = do
        -- The one place a store is purged: under the lock, and before anything
        -- is fetched, so that no run writes a pipeline and removes it in the
        -- same breath. @--clear-timestamp@ deliberately does not purge — it is
        -- the command a damaged store is repaired with.
        purged <- liftIO (storePurgeExpired store)
        case describePurged purged of
            Just what -> logInfo_ what
            Nothing -> logTrace_ "Nothing in the store has expired"

        token <-
            liftIO (tokenFile opts >>= readToken)
                >>= either (\err -> abort ("Cannot read the access token: " <> err)) pure

        logInfo_ $ "Fetching " <> optProject opts <> " from " <> optServerUrl opts

        limiter <- liftIO $ newRateLimiter requestsPerSecond
        -- Every request announces itself at trace level. On the terminal that is
        -- normally filtered out; in a --log file it is what shows a run pausing
        -- for a slow page rather than having stopped.
        announce <- requestAnnouncer
        manager <- liftIO $ rateLimitedManager limiter announce >>= addUserAgent
        -- Every request a run makes goes through one of these two, so waiting
        -- out a challenge here covers the record pages and the discussions
        -- alike, without either of them having to know what a challenge is.
        let gitlab :: GitLab c -> LogT IO (Either GitLabError c)
            gitlab =
                waitOutChallenge challengeWaits
                    . liftIO
                    . runGitLabWithManagerUnchecked manager (serverConfig opts token)

        -- The one call that checks the token, so that the thousands to follow do
        -- not each pay for a second request saying the same thing.
        prj <-
            waitOutChallenge
                challengeWaits
                (liftIO (runGitLabWithManager manager (serverConfig opts token) (lookupProject (optProject opts))))
                >>= either (\err -> abort ("GitLab request failed: " <> tshow err)) pure

        case (optJobLog opts, optPipelines opts, optSince opts) of
            (Just job, _, _) -> fetchJobLog gitlab store prj job
            (Nothing, Just (PipelineRequest (Just mr) withSummary), _) ->
                fetchMrPipelines gitlab store prj withSummary mr
            (Nothing, Just (PipelineRequest Nothing withSummary), Just when_) ->
                liftIO (resolveNow when_) >>= fetchPipelinesSince gitlab store prj withSummary
            -- 'FetchGitLab.Options.checkCommand' turns this down before a run starts.
            (Nothing, Just (PipelineRequest Nothing _), Nothing) ->
                abort "--pipelines needs a merge request or --since"
            (Nothing, Nothing, _) -> fetchTicketsAndMrs gitlab store prj opts

    terminalLevel
        | optVerbose opts = LogTrace
        | otherwise = LogInfo

-- | What this tool calls itself: @fetch-gitlab/<version>@.
userAgent :: Text
userAgent = "fetch-gitlab/" <> T.pack (showVersion version)

{- | Make a manager send 'userAgent' with every request.

Neither @http-client@ nor @gitlab-haskell@ sets a User-Agent, so without this
a run's requests carry none — and gitlab.haskell.org's anti-bot check treats
an anonymous client worse than one that says what it is.

Done on the manager rather than in the vendored library because it is the
tool that has a name and a version, and because it then covers every request
the library makes, the startup token check included. The hook is
@mModifyRequest@, which runs more than once per request; replacing the
header rather than adding to it keeps that harmless.
-}
addUserAgent :: Manager -> IO Manager
addUserAgent manager =
    pure manager{mModifyRequest = fmap setUserAgent . mModifyRequest manager}
  where
    setUserAgent :: Request -> Request
    setUserAgent req =
        req
            { requestHeaders =
                (hUserAgent, encodeUtf8 userAgent)
                    : filter ((/= hUserAgent) . fst) (requestHeaders req)
            }

{- | How long to wait, in seconds, after each successive anti-bot challenge.

The challenge clears on its own once traffic drops. Ten minutes was measured
to be enough and twenty seconds was measured not to be, so this starts well
under the known-good figure — no point waiting ten minutes for something that
might clear in one — and ends well over it. The whole ladder is a little
under half an hour, which is nothing against a run that takes eight.
-}
challengeWaits :: [Int]
challengeWaits = [30, 60, 120, 300, 600, 600]

{- | An anti-bot interstitial, recognised from a response the library handed
back as an ordinary failure.

'GitLab.API.Issues.projectIssuesPage' and
'GitLab.API.MergeRequests.mergeRequestsWithPage' go through @gitlabGetPage@,
which raises 'GitLabChallengeError' for itself, so the record fetch never
reaches this. @gitlabGetOne@ and @gitlabGetMany@ hand the response back
instead -- see @vendor\/gitlab-haskell\/PATCHES.md@ -- so the project lookup
and every discussion meet a challenge as a plain 'Left' with a success
status and an HTML body. Recognising it here is what stops a run reading
half an hour of throttling as thousands of records that could not be
fetched.

The status matters as much as the body. A challenge is served with HTTP 200,
which is the whole difficulty with it; an HTML page under a 4xx or a 5xx is
a genuine failure and must not buy itself the retry ladder.
-}
challengeDetail :: Status -> BL.ByteString -> Maybe Text
challengeDetail status body
    | isSuccess && looksHtml && hasMarker = Just detail
    | otherwise = Nothing
  where
    code = statusCode status
    isSuccess = code >= 200 && code <= 226
    looksHtml = any (`T.isPrefixOf` T.stripStart beginning) ["<!doctype", "<html"]
    hasMarker =
        any (`T.isInfixOf` beginning) ["not a bot", "anubis", "checking your browser", "captcha"]
    -- Enough of the body to carry the marker past whatever <head> precedes it,
    -- and no more: this ends up in a log line.
    beginning = T.toLower (decodeUtf8Lenient (BL.toStrict (BL.take 4000 body)))
    detail = "HTTP " <> tshow code <> ", body began " <> tshow (T.take 300 beginning)

{- | Raise a challenge the library reported as an ordinary failure, so that
'waitOutChallenge' waits it out rather than the caller stepping over it.

Every other failure is passed through untouched. A note that genuinely
cannot be fetched should be skipped and asked for again next run, not waited
on for half an hour.
-}
orChallenge ::
    GitLab (Either (Response BL.ByteString) a) ->
    GitLab (Either (Response BL.ByteString) a)
orChallenge act = do
    result <- act
    case result of
        Left response
            | Just detail <- challengeDetail (responseStatus response) (responseBody response) ->
                throwError (GitLabChallengeError detail)
        _ -> pure result

{- | Run a GitLab action, waiting out an anti-bot challenge rather than failing
on it.

These come back with HTTP 200 and an HTML body and are transient, so the
useful response is to stop asking for a while. Without this a challenge is
indistinguishable from a hard failure: a run that starts inside an open one
dies on the token check having done nothing, and one that meets it later
spends the rest of the run making requests that cannot succeed and marking
records for retry it never had a chance to fetch.

Every other error is returned untouched on the first try, so a bad token
still fails immediately rather than after half an hour of politeness.

Giving up stops the run rather than returning the error to the caller. A
caller that skips and carries on would spend the ladder again on the next
record, and the one after that; and stopping costs nothing, because whatever
has been fetched is already written and the next run resumes from it.
-}
waitOutChallenge ::
    (MonadLog m, MonadIO m) => [Int] -> m (Either GitLabError a) -> m (Either GitLabError a)
waitOutChallenge = go
  where
    go waits act = do
        result <- act
        case result of
            Left (GitLabChallengeError detail) -> case waits of
                [] ->
                    abort $
                        "The server has been answering with an anti-bot challenge for "
                            <> tshow (sum challengeWaits `div` 60)
                            <> " minutes, so this run is stopping. Everything fetched so far is "
                            <> "written; a later run carries on from there."
                wait : rest -> do
                    logAttention_ $
                        "The server answered with an anti-bot challenge rather than data. Waiting "
                            <> tshow wait
                            <> "s before asking again ("
                            <> tshow (length rest)
                            <> " further attempts before giving up)"
                    logTrace_ detail
                    liftIO $ threadDelay (wait * 1000000)
                    go rest act
            _ -> pure result

{- | A callback the HTTP manager can use to report each request it makes.

Trace level, so it is the @--log@ file that carries it rather than the
terminal, unless @-v@ was asked for.
-}
requestAnnouncer :: (MonadLog m) => m (Text -> IO ())
requestAnnouncer = do
    logIO <- getLoggerIO
    pure $ \what -> do
        now <- getCurrentTime
        logIO now LogTrace what noData
  where
    noData :: Value
    noData = object []

-- | How many discussions to fetch between progress lines.
progressEvery :: Int
progressEvery = 20

{- | Fetch the discussions of every record that is missing one or whose record
has changed since we last looked.

The store says which those are ('storeDiscussionPlan') rather than a run
working it out from a snapshot it holds: notes are three quarters of a store
and a run needs none of their content, only the iids and the record version
to stamp what it fetches with.

A record whose stored discussion still matches it is skipped, so the one
request per object this costs is never spent twice on the same version of an
object. The two counts are logged: records already current, and records to
request. The second should track how much the project moved since the
previous run.

Records are visited newest first (approximately: the store orders on text
that does not quite sort chronologically, see @encodeTime@ in
"FetchGitLab.Store.Sqlite"), and each discussion is written in a
transaction of its own as it arrives. That is what makes stopping safe at
any point, and what makes the stamp meaningful: notes and the version they
were fetched for land together or not at all.

A record whose notes cannot be fetched is logged and left alone, so one bad
object does not abort a long run. It will be retried next time.
-}
fetchDiscussions ::
    (Record a, StoreBackend s, MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    Text ->
    s ->
    Proxy a ->
    -- | Fetch the notes of one record, given its iid.
    (Int -> GitLab (Either (Response BL.ByteString) [Note])) ->
    m ()
fetchDiscussions gitlab what backend proxy fetch = do
    plan <- liftIO (storeDiscussionPlan backend proxy)
    held <- liftIO (storeRecordCount backend proxy)
    let total = length plan
        -- Records we are not asking about again, which is the point of storing
        -- the discussion stamp at all.
        cached = held - total
    if null plan
        then
            logInfo_ $
                "All " <> tshow cached <> " " <> what <> " discussions are up to date, requesting none"
        else do
            logInfo_ $
                "Discussions for "
                    <> what
                    <> ": "
                    <> tshow cached
                    <> " already current, requesting "
                    <> tshow total
            forM_ (zip [1 :: Int ..] plan) $ \(done, (iid, stamp)) -> do
                result <- gitlab (orChallenge (fetch iid))
                case result of
                    Left err ->
                        logAttention_ $ "Skipping notes for " <> what <> " " <> tshow iid <> ": " <> tshow err
                    Right (Left response) ->
                        logAttention_ $
                            "Skipping notes for "
                                <> what
                                <> " "
                                <> tshow iid
                                <> ": HTTP "
                                <> tshow (statusCode (responseStatus response))
                    Right (Right notes) -> do
                        logTrace_ $ tshow (length notes) <> " notes for " <> what <> " " <> tshow iid
                        -- The stamp the plan gave, not the record as it stands now: see
                        -- 'FetchGitLab.Store.Class.storeWriteDiscussion'.
                        liftIO $ storeWriteDiscussion backend proxy iid stamp notes
                when (done `mod` progressEvery == 0 && done /= total) $
                    logInfo_ $
                        "Discussions: " <> tshow done <> "/" <> tshow total <> " " <> what
            logInfo_ $
                "Discussions for "
                    <> tshow total
                    <> " "
                    <> what
                    <> " written to "
                    <> storeLocation backend

{- | An ordinary run: Fetch any changed or missing MRs/Tickets.

We fetch anything that is new since the last `updated_at - 1s`.
-}
fetchTicketsAndMrs ::
    forall s m.
    (StoreBackend s, MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    s ->
    Project ->
    Options ->
    m ()
fetchTicketsAndMrs gitlab backend prj opts = do
    -- An explicit --since overrides where the store says to carry on from.
    -- Nothing else can move the starting point back.
    override <- liftIO $ traverse resolveNow (optSince opts)
    storedTickets <- liftIO $ storeLatestUpdate backend (Proxy :: Proxy Issue)
    storedMrs <- liftIO $ storeLatestUpdate backend (Proxy :: Proxy MergeRequest)
    let ticketsSince = maybe (fetchSince storedTickets) Just override
        mrsSince = maybe (fetchSince storedMrs) Just override
    logSince "tickets" ticketsSince
    logSince "merge requests" mrsSince

    fetchRecords gitlab "tickets" backend ticketsSince $ \since ->
        projectIssuesPage prj (issueFilters since) recordsPerPage
    fetchRecords gitlab "merge requests" backend mrsSince $ \since ->
        mergeRequestsWithPage prj (mrFilters since) recordsPerPage

    if optNotes opts
        then do
            fetchDiscussions gitlab "tickets" backend (Proxy :: Proxy Issue) $
                \iid -> issueNotes prj iid Nothing Nothing
            fetchDiscussions gitlab "merge requests" backend (Proxy :: Proxy MergeRequest) $
                \iid -> mergeRequestNotes prj iid Nothing Nothing
        else logInfo_ "Skipping discussions (--no-notes)"

{- | The pipelines of one merge request and the jobs of each, and with
@--with-summary@ each pipeline's test report summary. A handful of requests,
so everything is written once, at the end: re-running costs less than
reasoning about a store holding half a fetch.

Pipelines are never part of an ordinary run: a project the size of GHC runs
a pipeline per push, so following pipelines for every merge request would
dwarf the records themselves. Jobs are always fetched: they are one request
per pipeline (a page holds 100, GHC's nightly runs 73) and most of what a
pipeline is worth.

Everything is fetched as raw JSON rather than through the library's types,
because the store keeps a pipeline and a job verbatim; a typed model would
silently drop whatever fields it does not know.

Any failure aborts the run rather than skipping: nothing records what a
run skipped, so a skip would read as a pipeline that had no jobs.
-}
fetchMrPipelines ::
    forall s m.
    (StoreBackend s, MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    s ->
    Project ->
    -- | Whether to fetch test summaries.
    Bool ->
    -- | The merge request, by its iid.
    Int ->
    m ()
fetchMrPipelines gitlab backend prj withSummary mr = do
    pipelines <-
        fetchJSONList
            gitlab
            ("pipelines of merge request !" <> tshow mr)
            (projectPath prj <> "/merge_requests/" <> tshow mr <> "/pipelines")
            []
    logInfo_ $
        tshow (length pipelines) <> " pipelines for merge request !" <> tshow mr
    fetched <- forM pipelines $ \p -> do
        pid <- requirePipelineId p
        jobs <- fetchJobs gitlab prj pid
        summary <- if withSummary then Just <$> fetchTestSummary gitlab prj False pid else pure Nothing
        pure (pid, p, jobs, summary)
    liftIO $ storeWritePipelines backend "mr" mr [(p, jobs) | (_, p, jobs, _) <- fetched]
    summaries <- liftIO $ writeSummaries backend [(pid, p, summary) | (pid, p, _, summary) <- fetched]
    logInfo_ $
        "Pipelines for merge request !"
            <> tshow mr
            <> " ("
            <> tshow (sum [length jobs | (_, _, jobs, _) <- fetched])
            <> " jobs"
            <> summaryCount withSummary summaries
            <> ") written to "
            <> storeLocation backend

{- | Every pipeline of the project created after a time, oldest first, fetched
as 'fetchMrPipelines' fetches one merge request's.

Possibly hundreds, so each pipeline is written as soon as its jobs (and
summary) are in, in a transaction of its own: a run stopped halfway keeps
what it fetched. There is no watermark; every run lists the whole range it
is given, and skips the pipelines 'pipelineIsCurrent' says it already has,
so an overlapping window costs a listing page per hundred of those.

A pipeline is filed under the merge request its ref names, and otherwise
as its own owner; see 'pipelineOwner'. A pipeline deleted between listing
and fetching its summary has none, rather than stopping the run.
-}
fetchPipelinesSince ::
    forall s m.
    (StoreBackend s, MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    s ->
    Project ->
    -- | Whether to fetch test summaries.
    Bool ->
    UTCTime ->
    m ()
fetchPipelinesSince gitlab backend prj withSummary after = do
    listed <-
        fetchJSONList
            gitlab
            ("pipelines created after " <> tshow after)
            (projectPath prj <> "/pipelines")
            [ ("created_after", Just (BS8.pack (iso8601Show after)))
            , ("order_by", Just "id")
            , ("sort", Just "asc")
            ]
    withIds <- forM listed $ \p -> (\pid -> (pid, p)) <$> requirePipelineId p
    states <- liftIO $ storePipelineStates backend (map fst withIds)
    let current (pid, p) = maybe False (pipelineIsCurrent withSummary p) (Map.lookup pid states)
        pipelines = filter (not . current) withIds
        total = length pipelines
    logInfo_ $
        tshow (length listed)
            <> " pipelines created after "
            <> tshow after
            <> ": "
            <> tshow (length listed - total)
            <> " finished and already stored, fetching "
            <> tshow total
    counts <- forM (zip [1 :: Int ..] pipelines) $ \(done, (pid, p)) -> do
        jobs <- fetchJobs gitlab prj pid
        summary <- if withSummary then Just <$> fetchTestSummary gitlab prj True pid else pure Nothing
        let (kind, iid) = pipelineOwner pid (textField "ref" p)
        liftIO $ storeWritePipelines backend kind iid [(p, jobs)]
        stored <- liftIO $ writeSummaries backend [(pid, p, summary)]
        when (done `mod` progressEvery == 0 && done /= total) $
            logInfo_ $
                "Pipelines: " <> tshow done <> "/" <> tshow total
        pure (length jobs, stored)
    logInfo_ $
        tshow total
            <> " pipelines ("
            <> tshow (sum (map fst counts))
            <> " jobs"
            <> summaryCount withSummary (sum (map snd counts))
            <> ") written to "
            <> storeLocation backend

{- | Whether a listed pipeline is one the store already holds in full, so
that fetching its jobs (and summary) again would change nothing.

A pipeline's @updated_at@ moves with its own status and not with its jobs':
a running pipeline keeps the one it started with while its jobs finish.
So it only says "unchanged" once the status is final, and a retry, which
takes the pipeline back to running, moves it. Asked for summaries, the
summary must have been asked for this same @updated_at@ too -- whether or
not there was one, so a pipeline without a test report is not asked again.
-}
pipelineIsCurrent :: Bool -> Value -> PipelineState -> Bool
pipelineIsCurrent withSummary p st =
    maybe False (`elem` finalStatuses) status
        && stateStatus st == status
        && isJust updated
        && stateUpdatedAt st == updated
        && summaryCurrent
  where
    status = textField "status" p
    updated = textField "updated_at" p
    -- A run that does not fetch summaries has no use for a current one.
    summaryCurrent
        | withSummary = stateSummaryPipelineUpdatedAt st == updated
        | otherwise = True
    finalStatuses = ["success", "failed", "canceled", "skipped"]

textField :: Text -> Value -> Maybe Text
textField k = Aeson.parseMaybe (Aeson.withObject "object" (Aeson..: Key.fromText k))

{- | Which record a pipeline listed project-wide belongs to: the merge request
its ref names (@refs\/merge-requests\/N\/head@, @…\/merge@, @…\/train@),
and otherwise kind @pipeline@ with the pipeline's own id, which the store
reads as "owner unknown" and never puts over a known one.

A branch ref is not traced back to a merge request: the same branch can be
the source of several, and a push pipeline on it belongs to none of them.
-}
pipelineOwner :: Int -> Maybe Text -> (Text, Int)
pipelineOwner pid ref = case T.stripPrefix "refs/merge-requests/" =<< ref of
    Just rest
        | (digits, suffix) <- T.span isDigit rest
        , not (T.null digits)
        , suffix `elem` ["/head", "/merge", "/train"] ->
            ("mr", read (T.unpack digits))
    _ -> ("pipeline", pid)

{- | The jobs of one pipeline. Only the latest attempt of each; GitLab leaves
out retried ones unless asked.
-}
fetchJobs ::
    (MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    Project ->
    Int ->
    m [Value]
fetchJobs gitlab prj pid = do
    jobs <-
        fetchJSONList
            gitlab
            ("jobs of pipeline " <> tshow pid)
            (projectPath prj <> "/pipelines/" <> tshow pid <> "/jobs")
            []
    logTrace_ $ tshow (length jobs) <> " jobs in pipeline " <> tshow pid
    pure jobs

{- | The test report summary of one pipeline, or 'Nothing' when its jobs
uploaded no JUnit report: GitLab then answers with zero counts and no
suites, which says nothing worth storing.
-}
fetchTestSummary ::
    (MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    Project ->
    {- | Whether a 404 means "no summary" rather than a failure: for a pipeline
    listed a while ago, which may have been deleted since.
    -}
    Bool ->
    Int ->
    m (Maybe Value)
fetchTestSummary gitlab prj missingOk pid = do
    result <- gitlab (orChallenge (gitlabGetOne path []))
    case result of
        Left err -> abort ("Cannot fetch " <> what <> ": " <> tshow err)
        Right (Left response)
            | missingOk && statusCode (responseStatus response) == 404 -> none
            | otherwise ->
                abort ("Cannot fetch " <> what <> ": HTTP " <> tshow (statusCode (responseStatus response)))
        Right (Right summary) -> maybe none (pure . Just) (usableSummary =<< summary)
  where
    what = "the test report summary of pipeline " <> tshow pid
    path = projectPath prj <> "/pipelines/" <> tshow pid <> "/test_report_summary"
    none = do
        logTrace_ $ "No test report for pipeline " <> tshow pid
        pure Nothing

{- | A summary worth storing: one with at least one suite. GitLab answers a
pipeline without JUnit reports -- or whose report artifacts have expired --
with zero counts and no suites, and storing that would put nothing over a
summary fetched while the artifacts were there.
-}
usableSummary :: Value -> Maybe Value
usableSummary v = case Aeson.parseMaybe (Aeson.withObject "summary" (Aeson..: "test_suites")) v of
    Just (Array suites) | not (null suites) -> Just v
    _ -> Nothing

{- | Record, after their pipelines, the summaries that were asked for --
'Nothing' for a pipeline they were not asked for, @Just Nothing@ for one
without -- stamped with the @updated_at@ of the pipeline as it was listed,
not as it may be now: a pipeline that moved in between must look stale.
Returns how many summaries there were.
-}
writeSummaries :: (StoreBackend s) => s -> [(Int, Value, Maybe (Maybe Value))] -> IO Int
writeSummaries backend summaries = do
    forM_ [(pid, p, v) | (pid, p, Just v) <- summaries] $ \(pid, p, v) ->
        storeWriteTestSummary backend pid (textField "updated_at" p) v
    pure (length [() | (_, _, Just (Just _)) <- summaries])

{- | The part of a closing log line that counts summaries, when they were
asked for.
-}
summaryCount :: Bool -> Int -> Text
summaryCount False _ = ""
summaryCount True n = ", " <> tshow n <> " test summaries"

-- | A collection in raw JSON, every page of it. Any failure aborts the run.
fetchJSONList ::
    (MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    -- | What is being fetched, for the message if it cannot be.
    Text ->
    Text ->
    [(BS.ByteString, Maybe BS.ByteString)] ->
    m [Value]
fetchJSONList gitlab what path params = do
    result <- gitlab (orChallenge (gitlabGetMany path params))
    case result of
        Left err -> abort ("Cannot fetch " <> what <> ": " <> tshow err)
        Right (Left response) ->
            abort
                ( "Cannot fetch "
                    <> what
                    <> ": HTTP "
                    <> tshow (statusCode (responseStatus response))
                )
        Right (Right values) -> pure values

requirePipelineId :: (MonadLog m, MonadIO m) => Value -> m Int
requirePipelineId p = case Aeson.parseMaybe (Aeson.withObject "pipeline" (Aeson..: "id")) p of
    Nothing -> abort "GitLab sent a pipeline without an id"
    Just pid -> pure pid

projectPath :: Project -> Text
projectPath prj = "/projects/" <> tshow (project_id prj)

{- | Fetch the log of one job into the store, replacing any log held for it.
It is stored cleaned, never as sent: see "FetchGitLab.JobLog".

Checks if the associated job is locally cached before fetching it's log.

Detects Anubis responses via orChallenge since those return HTTP200.
-}
fetchJobLog ::
    forall s m.
    (StoreBackend s, MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    s ->
    Project ->
    -- | The job, by its GitLab id.
    Int ->
    m ()
fetchJobLog gitlab backend prj job = do
    known <- liftIO $ storeHasJob backend job
    when (not known) $
        abort
            ( "Job "
                <> tshow job
                <> " is not in "
                <> storeLocation backend
                <> "; fetch its merge request with --pipelines first"
            )
    result <- gitlab (orChallenge (classify <$> gitlabGetByteStringResponse path []))
    raw <- case result of
        Left err -> abort ("Cannot fetch the log of job " <> tshow job <> ": " <> tshow err)
        Right (Left response) ->
            abort
                ( "Cannot fetch the log of job "
                    <> tshow job
                    <> ": HTTP "
                    <> tshow (statusCode (responseStatus response))
                )
        Right (Right body) -> pure (BL.toStrict body)
    -- Whatever the server sent that was not UTF-8 is a replacement character
    -- after this, and no control character is left, so what is stored is text.
    let body = stripControlChars (decodeUtf8Lenient raw)
    liftIO $ storeWriteJobLog backend job body
    logInfo_ $
        "Log of job "
            <> tshow job
            <> " ("
            <> tshow (T.count "\n" body)
            <> " lines, "
            <> tshow (BS.length raw)
            <> " bytes as sent) written to "
            <> storeLocation backend
  where
    path = "/projects/" <> tshow (project_id prj) <> "/jobs/" <> tshow job <> "/trace"

    classify response
        | Just _ <- challengeDetail status (responseBody response) = Left response
        | statusIsSuccessful status = Right (responseBody response)
        | otherwise = Left response
      where
        status = responseStatus response

-- | Log a reason the run cannot go on, and stop.
abort :: (MonadLog m, MonadIO m) => Text -> m a
abort msg = do
    logAttention_ msg
    liftIO exitFailure

{- | Fetch a collection a page at a time, writing each page to the store before
asking for the next one.

Asking for the whole collection in one call meant minutes with nothing to
show and nothing saved: a run that was paging through twenty thousand issues
looked exactly like one that had wedged, and stopping it threw all of it
away. A page is one request, so writing every page reports progress as often
as there is progress to report, without spending a request to do it.

Pages are anchored on @updated_at@ rather than numbered. Each one asks for
the records updated after the newest we have, oldest first, which is what
makes stopping halfway safe: the next run derives what to ask for from the
newest record in the store, so a store holding the first half of a
collection asks for exactly the second half. Numbered pages would break that
twice over -- the newest records arrive first, so a partial run would leave
a watermark past everything it had not fetched, and a record edited while we
page moves within the collection and shifts a neighbour out of the numbering
unseen.

The count of records we already had at the same @updated_at@ is logged
because it says how much of the fetch was wasted. It is normally small and
never zero once a store exists: 'fetchSince' deliberately asks from a second
before our newest record, so whatever sits in that second comes back again.
A large count means the timestamp we asked from was further back than it
needed to be.
-}
fetchRecords ::
    forall a s m.
    (Record a, StoreBackend s, MonadLog m, MonadIO m) =>
    (forall b. GitLab b -> m (Either GitLabError b)) ->
    Text ->
    s ->
    -- | Where to start, or 'Nothing' to fetch the whole collection.
    Maybe UTCTime ->
    -- | One page of records updated at or after the given time, oldest first.
    (Maybe UTCTime -> GitLab [a]) ->
    m ()
fetchRecords gitlab what backend start page = go start IntSet.empty 0
  where
    proxy = Proxy :: Proxy a

    go anchor seen cached = do
        result <- gitlab (page (addUTCTime (-overlap) <$> anchor))
        records <- either (\err -> abort ("GitLab request failed: " <> tshow err)) pure result
        let fresh = filter (not . (`IntSet.member` seen) . recordKey) records
            seen' = IntSet.union seen (IntSet.fromList (map recordKey records))
            newest = maximumOf (mapMaybe recordUpdatedAt records)
        -- Asked before the page is written, since writing it is what makes the
        -- answer "current".
        stored <- liftIO $ storeRecordVersions backend proxy (map recordKey fresh)
        let cached' = cached + length (filter (unchanged stored) fresh)
        liftIO $ storeWriteRecords backend records
        if length records < recordsPerPage
            then do
                let fetched = IntSet.size seen'
                held <- liftIO (storeRecordCount backend proxy)
                logInfo_ $
                    "Fetched "
                        <> tshow fetched
                        <> " "
                        <> what
                        <> " ("
                        <> tshow (fetched - cached')
                        <> " new or changed, "
                        <> tshow cached'
                        <> " already current), store now holds "
                        <> tshow held
            else do
                logInfo_ $
                    "Fetching "
                        <> what
                        <> ": "
                        <> tshow (IntSet.size seen')
                        <> " so far, written up to "
                        <> maybe "an unknown time" tshow newest
                case newest of
                    Just t | maybe True (t >) anchor -> go (Just t) seen' cached'
                    -- A whole page of records sharing one instant, so there is no
                    -- later time to ask from. Stepping past it is the only way on;
                    -- anything it skips has an older timestamp than the store's
                    -- newest record and so comes back on the next run.
                    _ -> case anchor of
                        Just t -> do
                            logAttention_ $
                                "A full page of "
                                    <> what
                                    <> " is stamped "
                                    <> tshow t
                                    <> "; stepping past it, some may be left for the next run"
                            go (Just (addUTCTime (overlap + tick) t)) seen' cached'
                        Nothing -> do
                            logAttention_ $
                                "GitLab gave no update time for any of the first "
                                    <> tshow recordsPerPage
                                    <> " "
                                    <> what
                                    <> ", so there is nothing to page on; stopping here"

    -- The store already had this record at exactly this version, which is
    -- the condition under which writing it changes nothing and its discussion
    -- stays current. This is what the run fetched for nothing.
    unchanged stored r = Map.lookup (recordKey r) stored == Just (recordUpdatedAt r)

    -- GitLab reads @updated_after@ as "at or after", so asking from exactly
    -- the newest record we hold returns that record again, which is harmless.
    -- Going back a further millisecond costs one more repeat and covers a
    -- server that reads it as "after".
    overlap = 0.001
    tick = 0.000001

    maximumOf [] = Nothing
    maximumOf ts = Just (maximum ts)

{- | Timestamp to request updates from, or 'Nothing' to fetch everything.

We go back a second from the newest timestamp the store holds, so that a
record modified in the same instant as our newest one cannot fall through an
exclusive @updated_after@ comparison. Re-fetching a record we already have is
harmless, it just replaces itself. The second also covers the store's answer
being under a second out: it is a @MAX@ over text that does not sort
chronologically; see @encodeTime@ in "FetchGitLab.Store.Sqlite".
-}
fetchSince :: Maybe UTCTime -> Maybe UTCTime
fetchSince = fmap (addUTCTime (-1))

-- | Resolve a @--since@ argument against the current time.
resolveNow :: Since -> IO UTCTime
resolveNow s = flip resolveSince s <$> getCurrentTime

{- | Oldest change first, so that a run stopped halfway leaves a store whose
newest record is exactly where the next one should carry on from. See
'fetchRecords'.
-}
issueFilters :: Maybe UTCTime -> IssueFilterAttrs
issueFilters since =
    def
        { issueFilter_updated_after = since
        , issueFilter_order_by = Just UpdatedAt
        , issueFilter_sort = Just Ascending
        }

mrFilters :: Maybe UTCTime -> MergeProjectAttrs
mrFilters since =
    mrAttrs
        { mr_attr_updated_after = since
        , mr_attr_order_by = Just UpdatedAt
        , mr_attr_sort = Just Ascending
        }

-- | Look up the project to fetch from, given as @namespace/project@.
lookupProject :: Text -> GitLab Project
lookupProject fullPath = do
    result <- orChallenge (projectWithPathAndName namespace name)
    case result of
        Left _ -> notFound
        Right Nothing -> notFound
        Right (Just prj) -> pure prj
  where
    notFound = throwError (GitLabError ("no such project: " <> fullPath))

    (namespace, name) = case T.breakOnEnd "/" fullPath of
        (ns, n) -> (T.dropEnd 1 ns, n)

logSince :: (MonadLog m) => Text -> Maybe UTCTime -> m ()
logSince what Nothing = logInfo_ $ "No " <> what <> " stored yet, fetching all of them"
logSince what (Just t) = logInfo_ $ "Fetching " <> what <> " updated after " <> tshow t

tshow :: (Show a) => a -> Text
tshow = T.pack . show
