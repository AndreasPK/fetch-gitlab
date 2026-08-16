module Main (main) where

import Options.Applicative (execParser)

import FetchGitLab.Show (runShow, showParserInfo)

main :: IO ()
main = execParser showParserInfo >>= runShow
