{-# LANGUAGE OverloadedStrings #-}

-- | Excluding concurrent runs from the same store files.
--
-- Not because they would lose each other's work. Every write a run makes
-- states one thing it has just learned and lands in an immediate transaction
-- of its own, so two runs sharing a store can duplicate work but cannot undo
-- it; see "FetchGitLab.Store.Class".
--
-- What the lock buys is the cost of that duplication. A cold run over a
-- project the size of GHC's is tens of thousands of requests and the better
-- part of a day, and two runs against one token double the rate at a server
-- that answers sustained traffic with an anti-bot challenge — so the second
-- run would make the first one slower and finish with nothing new. An
-- exclusive lock held for the whole run turns it away at once instead, and
-- names the process it is waiting on so the answer is actionable.
module FetchGitLab.Lock
  ( withStoreLocks
  , LockBusy (..)
  , LockInfo (..)
  , lockPath
  , readLockInfo
  ) where

import Control.Exception (finally, try)
import Data.Aeson (FromJSON (..), ToJSON (..), decode, encode, object, withObject, (.:), (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.IO.Handle.Lock (LockMode (ExclusiveLock), hTryLock)
import System.Directory (doesFileExist)
import System.IO (IOMode (ReadWriteMode), SeekMode (AbsoluteSeek), hClose, hFlush, hSeek, hSetFileSize, openFile)
import System.IO.Error (isAlreadyInUseError)
import System.Process (getCurrentPid)

-- | Who holds a lock, as recorded in the lock file.
--
-- Written for diagnosis only. The lock itself is a real file lock, so it is
-- the operating system rather than this record that decides whether another
-- run gets in; see 'withStoreLocks'.
data LockInfo = LockInfo
  { lockPid :: Int
    -- ^ Process id of the run holding the lock.
  , lockStartedAt :: UTCTime
    -- ^ When that run took the lock.
  }
  deriving (Eq, Show)

instance ToJSON LockInfo where
  toJSON i = object ["pid" .= lockPid i, "started_at" .= lockStartedAt i]

instance FromJSON LockInfo where
  parseJSON = withObject "LockInfo" $ \o -> LockInfo <$> o .: "pid" <*> o .: "started_at"

-- | A store we could not lock, and whoever we found holding it.
data LockBusy = LockBusy
  { busyStore :: FilePath
    -- ^ The store file, not its lock file.
  , busyHolder :: Maybe LockInfo
    -- ^ 'Nothing' if the lock file was empty or unreadable, which is what a
    -- reader sees in the moment between the holder taking the lock and
    -- describing itself.
  }
  deriving (Eq, Show)

-- | The lock file guarding a store file.
--
-- The lock lives beside the store rather than on it because a store file is
-- not guaranteed to stay the same inode: a backend that replaces it by
-- renaming a temporary file into place would leave the lock holding the
-- replaced inode, and the next run would open the new one and lock it
-- happily. The lock file itself is only ever created, locked and rewritten in
-- place, so every run ends up contending for the same inode.
lockPath :: FilePath -> FilePath
lockPath path = path <> ".lock"

-- | Read what a lock file says about its holder.
--
-- Returns 'Nothing' for a missing, empty or unparseable file. Note that a lock
-- file left over from a finished run still has its old contents: the file is
-- not removed on release, so this says who last /took/ the lock, not that the
-- lock is currently held.
-- Reporting who is in the way must not itself be able to fail, so an
-- unreadable lock file is 'Nothing' like an unparseable one. This is not
-- hypothetical: a lock file already open for writing in /this/ process cannot
-- be read at all, GHC refusing it before the filesystem is consulted.
readLockInfo :: FilePath -> IO (Maybe LockInfo)
readLockInfo path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      contents <- try (BL.readFile path)
      pure $ case contents of
        Left e -> const Nothing (e :: IOError)
        Right bytes -> decode bytes

-- | Run an action holding an exclusive lock on each of the given store files.
--
-- Returns 'Left' describing the first store another process already holds,
-- without running the action. Locking does not wait: a run takes hours, so
-- queueing behind one is far more likely to be a mistake than the intent.
--
-- The locks are released when the action finishes, and by the operating system
-- if the process dies without getting that far. That is what makes a stale
-- lock impossible rather than merely unlikely: a lock file whose recorded
-- process is long gone does not hold anything, and the next run overwrites it.
-- The recorded pid and time are therefore for reporting who is in the way, not
-- for deciding whether to believe the lock.
withStoreLocks :: [FilePath] -> IO a -> IO (Either LockBusy a)
withStoreLocks paths act = go paths
  where
    go [] = Right <$> act
    go (path : rest) = do
      -- Opening can fail with "resource busy" in its own right, because a file
      -- already open for writing in this process is refused by GHC before any
      -- file lock is asked for. That is the same answer as a refused lock, so
      -- it gets the same reply rather than an exception out of a lock check.
      opened <- try (openFile (lockPath path) ReadWriteMode)
      case opened of
        Left e
          -- No handle, so no way to say who holds it. Only reachable within
          -- one process, where the holder is us anyway.
          | isAlreadyInUseError e -> pure (Left (LockBusy path Nothing))
          | otherwise -> ioError e
        -- Closing the handle releases the lock, so this covers both.
        Right h -> flip finally (hClose h) $ do
          locked <- hTryLock h ExclusiveLock
          if locked
            then describeHolder h >> go rest
            else Left . LockBusy path <$> holderOf h

    -- Read through the handle we already have rather than opening the lock
    -- file a second time: this process has it open for writing, and GHC
    -- refuses a second open of that regardless of who holds the file lock.
    holderOf h = do
      contents <- try $ do
        hSeek h AbsoluteSeek 0
        BS.hGetContents h
      pure $ case contents of
        Left e -> const Nothing (e :: IOError)
        Right bytes -> decode (BL.fromStrict bytes)

    -- Replace whatever the previous holder wrote with our own details.
    describeHolder h = do
      info <- LockInfo <$> (fromIntegral <$> getCurrentPid) <*> getCurrentTime
      hSetFileSize h 0
      hSeek h AbsoluteSeek 0
      BL.hPut h (encode info <> "\n")
      -- Flushed so that a run blocked on this lock can read it right away.
      hFlush h
