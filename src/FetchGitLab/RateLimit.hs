-- | A simple global rate limiter, and an HTTP manager that obeys it.
module FetchGitLab.RateLimit
  ( RateLimiter
  , newRateLimiter
  , waitTurn
  , rateLimitedManager
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, modifyMVar_, newMVar)
import Control.Monad (when)
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Client (Manager, ManagerSettings (..), newManager)
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

-- | Block until the next request is allowed to go out.
--
-- The 'MVar' is held while sleeping, so concurrent callers queue up rather
-- than all waking up for the same slot.
waitTurn :: RateLimiter -> IO ()
waitTurn limiter = modifyMVar_ (rlNextSlot limiter) $ \next -> do
  now <- getMonotonicTime
  let slot = max now next
  when (slot > now) $ threadDelay (round ((slot - now) * 1e6))
  pure (slot + rlInterval limiter)

-- | An HTTP manager that waits for its turn before every request.
--
-- Hooking the manager rather than the individual API calls means pagination
-- and retries performed inside @gitlab-haskell@ are rate limited too.
rateLimitedManager :: RateLimiter -> IO Manager
rateLimitedManager limiter =
  newManager
    tlsManagerSettings
      { managerModifyRequest = \req -> waitTurn limiter >> pure req
      }
