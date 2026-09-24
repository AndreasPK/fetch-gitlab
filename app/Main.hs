module Main (main) where

import Options.Applicative (defaultPrefs, handleParseResult)
import System.Environment (getArgs)

import FetchGitLab.ClearTimestamp (runClearTimestamp)
import FetchGitLab.Fetch (run)
import FetchGitLab.Options (Command (..), commandResult)

main :: IO ()
main = do
    command <- getArgs >>= handleParseResult . commandResult defaultPrefs
    case command of
        Fetch opts -> run opts
        ClearTimestamp opts -> runClearTimestamp opts
