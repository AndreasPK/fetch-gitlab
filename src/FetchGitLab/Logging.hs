{-# LANGUAGE OverloadedStrings #-}

-- | Where a run's log lines go.
module FetchGitLab.Logging (
    withFetchLogger,
) where

import Control.Exception (bracket, try)
import Control.Monad (when)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import System.Directory (createDirectoryIfMissing)
import System.Exit (exitFailure)
import System.FilePath (takeDirectory)
import System.IO (
    BufferMode (LineBuffering),
    Handle,
    IOMode (AppendMode),
    hClose,
    hFlush,
    hSetBuffering,
    openFile,
    stdout,
 )
import System.IO.Error (ioeGetErrorString)

import Log (
    LogLevel (..),
    LogMessage (..),
    Logger,
    logAttention_,
    mkLogger,
    runLogT,
    showLogMessage,
 )
import Log.Internal.Logger (withLogger)

{- | Run an action with a logger for the terminal and, if one was asked for, a
file as well.

The two are given different amounts on purpose. The terminal keeps the level
the command line asked for, normally info, because it is read as the run
goes. The file gets everything down to trace, which is a line per HTTP
request, so that a run which has gone quiet can be told apart from one
working through a long stretch of pagination. Telling those two apart is the
only reason the file exists.

The 'LogLevel' handed to the action is what to give 'runLogT'. It is trace
whenever a file is being written, since a message filtered out there would
never reach the file either; the terminal then does its own filtering.
-}
withFetchLogger :: Maybe FilePath -> LogLevel -> (Logger -> LogLevel -> IO r) -> IO r
withFetchLogger mpath terminalLevel act = do
    terminal <- terminalLogger terminalLevel
    withLogger terminal $ \out -> case mpath of
        Nothing -> act out terminalLevel
        Just path ->
            bracket (openLogFile out terminalLevel path) hClose $ \handle -> do
                toFile <- mkLogger "log-file" (writeMessage handle)
                withLogger toFile $ \file -> act (out <> file) LogTrace

{- | Everything at or above the level asked for, flushed as it goes so that a
terminal shows progress rather than a run's worth of output at the end.
-}
terminalLogger :: LogLevel -> IO Logger
terminalLogger level = mkLogger "stdout" $ \message ->
    when (lmLevel message <= level) $ do
        T.putStrLn (showLogMessage Nothing message)
        hFlush stdout

writeMessage :: Handle -> LogMessage -> IO ()
writeMessage handle = T.hPutStrLn handle . showLogMessage Nothing

{- | Open the log file, appending so that an earlier run's log is not thrown
away, and line buffered so that tailing it shows the run as it happens.

A log file that cannot be opened stops the run: it was asked for, and a run
that quietly did without it would be a run nobody could watch.
-}
openLogFile :: Logger -> LogLevel -> FilePath -> IO Handle
openLogFile logger level path = do
    opened <- try $ do
        createDirectoryIfMissing True (takeDirectory path)
        handle <- openFile path AppendMode
        hSetBuffering handle LineBuffering
        pure handle
    case opened of
        Right handle -> pure handle
        Left err -> do
            runLogT "fetch-gitlab" logger level . logAttention_ $
                "Cannot write the log file "
                    <> T.pack (show path)
                    <> ": "
                    <> T.pack (ioeGetErrorString (err :: IOError))
            exitFailure
