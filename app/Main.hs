module Main (main) where

import Options.Applicative (execParser)

import FetchGitLab.ClearTimestamp (runClearTimestamp)
import FetchGitLab.Fetch (run)
import FetchGitLab.Options (Command (..), commandParserInfo)

main :: IO ()
main = do
    command <- execParser commandParserInfo
    case command of
        Fetch opts -> run opts
        ClearTimestamp opts -> runClearTimestamp opts
