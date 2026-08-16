module Main (main) where

import Options.Applicative (execParser)

import FetchGitLab.Fetch (run)
import FetchGitLab.Options (optionsParserInfo)

main :: IO ()
main = execParser optionsParserInfo >>= run
