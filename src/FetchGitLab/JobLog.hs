{-# LANGUAGE OverloadedStrings #-}

-- | Making a CI job's log greppable.
--
-- A job log ("trace") is what a terminal was sent, not what it showed: colour
-- is ANSI escape sequences, GitLab's collapsible sections are
-- @section_start:\<time\>:\<name\>@ markers hidden behind a carriage return
-- and an erase-line sequence, and a progress line is one line of output
-- rewritten many times over with carriage returns. Searching that finds
-- matches split by a colour change and misses ones at the start of a line
-- that does not start where it appears to.
--
-- 'stripControlChars' reduces a log to the text a reader of the terminal
-- would have been left looking at, and that is the only form @--job-log@
-- stores. The log as sent stays a request away, at the job's @\/trace@.
module FetchGitLab.JobLog
  ( stripControlChars
  ) where

import Data.Char (isControl)
import Data.Text (Text)
import qualified Data.Text as T

-- | Remove terminal control from a log, keeping its lines and their order.
--
-- * Escape sequences go: CSI (@ESC [ … m@ and the rest of that family), OSC
--   (@ESC ] … BEL@ or @… ESC \\@), and the short forms (@ESC ( B@, @ESC 7@).
-- * Of a line rewritten with carriage returns only what was written last
--   survives, which is also what removes the section markers. A carriage
--   return that merely ends the line, as in @\\r\\n@, overwrites nothing.
-- * Every other control character goes, tab excepted.
--
-- Newlines are never touched, so line numbers in the result are line numbers
-- in the log.
stripControlChars :: Text -> Text
stripControlChars =
  T.intercalate "\n" . map cleanLine . T.splitOn "\n" . stripEscapes
  where
    cleanLine = T.filter keep . lastWritten . T.dropWhileEnd (== '\r')
    lastWritten = snd . T.breakOnEnd "\r"
    keep c = c == '\t' || not (isControl c)

-- | Remove every escape sequence, and an @ESC@ that starts none.
--
-- A sequence that never ends must not take the rest of the log with it, so a
-- malformed one stops at the first character that cannot belong to it: what
-- follows is kept, newline included.
stripEscapes :: Text -> Text
stripEscapes = T.concat . go
  where
    go t = case T.break (== '\ESC') t of
      (before, rest) -> case T.uncons rest of
        Nothing -> [before]
        Just (_, afterEsc) -> before : go (dropSequence afterEsc)

    -- The text after an ESC, less the sequence that ESC introduced.
    dropSequence t = case T.uncons t of
      Just ('[', r) -> dropFinal '\x40' (T.dropWhile isParameter r)
      Just (']', r) -> dropTerminator (T.dropWhile inString r)
      Just (c, r)
        | isIntermediate c -> dropFinal '\x30' (T.dropWhile isIntermediate r)
        | c >= '\x30' && c <= '\x7e' -> r
      _ -> t

    -- CSI parameter and intermediate bytes; between them they are one range.
    isParameter c = c >= '\x20' && c <= '\x3f'
    isIntermediate c = c >= '\x20' && c <= '\x2f'

    -- The byte that ends a sequence, if that is what comes next.
    dropFinal lowest t = case T.uncons t of
      Just (c, r) | c >= lowest && c <= '\x7e' -> r
      _ -> t

    -- An OSC string runs to a BEL or to ESC \. Stopping at a newline as well
    -- is the guard against one that was cut off.
    inString c = c /= '\BEL' && c /= '\ESC' && c /= '\n'
    dropTerminator t = case T.uncons t of
      Just ('\BEL', r) -> r
      Just ('\ESC', r) | Just ('\\', r') <- T.uncons r -> r'
      _ -> t
