{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | A simple global rate limiter, and an HTTP manager that obeys it.
module FetchGitLab.RateLimit (
    RateLimiter,
    newRateLimiter,
    waitTurn,
    rateLimitedManager,
) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Control.Monad (when)
import Data.Text (Text)
import Data.Text.Encoding (decodeUtf8Lenient)
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Client (
    Manager,
    ManagerSettings (..),
    Request,
    host,
    method,
    newManager,
    path,
    queryString,
 )
import Network.HTTP.Client.TLS (tlsManagerSettings)

-- | Allows at most one request per 'rlInterval' seconds.
data RateLimiter = RateLimiter
    { rlInterval :: Double
    -- ^ Minimum number of seconds between two requests.
    , rlNextSlot :: MVar Double
    -- ^ Monotonic time at which the next request may start.
    }

-- | Create a limiter allowing the given number of requests per second.
newRateLimiter :: Double -> IO RateLimiter
newRateLimiter perSecond = RateLimiter (1 / perSecond) <$> newMVar 0

{- | Block until the next request is allowed to go out.

The 'MVar' is held while sleeping, so concurrent callers queue up rather
than all waking up for the same slot.
-}
waitTurn :: RateLimiter -> IO ()
waitTurn limiter = modifyMVar_ (rlNextSlot limiter) $ \next -> do
    now <- getMonotonicTime
    let slot = max now next
    when (slot > now) $ threadDelay (round ((slot - now) * 1e6))
    pure (slot + rlInterval limiter)

{- | An HTTP manager that waits for its turn before every request, and says
what it is about to ask for.

Hooking the manager rather than the individual API calls means pagination
and retries performed inside @gitlab-haskell@ are rate limited too — and,
for the same reason, that they are the only thing that reports them. A run
spends minutes inside a single library call while it pages through a
collection, so without this there is nothing to distinguish that from a run
that has wedged.

The hook is 'managerWrapException', which is not what its name suggests it
is for. The obvious choice, 'managerModifyRequest', runs /twice/ per
request: @responseOpen@ applies it once to the request it is given and then
again inside the redirect loop before each attempt. Waiting there halves the
rate we actually achieve and doubles what the log claims we asked for.
'managerWrapException' wraps the whole of @responseOpen@ and so runs exactly
once per request, retries included. The default wrapper is still called, so
exceptions are translated as they would have been.
-}
rateLimitedManager :: RateLimiter -> (Text -> IO ()) -> IO Manager
rateLimitedManager limiter announce =
    newManager
        tlsManagerSettings
            { managerWrapException = \req action -> do
                waitTurn limiter
                announce (describeRequest req)
                managerWrapException tlsManagerSettings req action
            }

{- | A request, short enough to be one log line.

The access token is sent as a @PRIVATE-TOKEN@ header rather than in the
query string, so this cannot put it in the log.
-}
describeRequest :: Request -> Text
describeRequest req =
    utf8 (method req)
        <> " https://"
        <> utf8 (host req)
        <> utf8 (path req)
        <> utf8 (queryString req)
  where
    utf8 = decodeUtf8Lenient
