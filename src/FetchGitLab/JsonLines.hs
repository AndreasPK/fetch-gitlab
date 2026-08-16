{-# LANGUAGE OverloadedStrings #-}

-- | Writing values in JSON lines format (one JSON value per line).
module FetchGitLab.JsonLines
  ( writeJsonLines
  , appendJsonLines
  , encodeJsonLines
  ) where

import Data.Aeson (ToJSON, encode)
import qualified Data.ByteString.Lazy as BL

-- | Encode values as JSON lines. Each value takes up exactly one line,
-- terminated by a newline.
encodeJsonLines :: ToJSON a => [a] -> BL.ByteString
encodeJsonLines = BL.concat . map (\x -> encode x <> "\n")

-- | Write values to a file in JSON lines format, replacing the file.
writeJsonLines :: ToJSON a => FilePath -> [a] -> IO ()
writeJsonLines path = BL.writeFile path . encodeJsonLines

-- | Append values to a file in JSON lines format.
appendJsonLines :: ToJSON a => FilePath -> [a] -> IO ()
appendJsonLines path = BL.appendFile path . encodeJsonLines
