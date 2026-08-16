-- | Points in time as given on the command line.
--
-- Accepts both absolute timestamps and git style relative ones, so
-- @--since \"2 weeks\"@ works as well as @--since 2026-08-01@.
module FetchGitLab.Since
  ( Since (..)
  , Unit (..)
  , parseSince
  , resolveSince
  ) where

import Data.Char (isDigit, isSpace, toLower)
import Data.List (stripPrefix)
import Data.Time.Calendar (addGregorianMonthsClip, addGregorianYearsClip)
import Data.Time.Clock (UTCTime (..), addUTCTime, nominalDay)
import Data.Time.Format.ISO8601 (iso8601ParseM)

-- | A point in time, either absolute or relative to the current moment.
data Since
  = -- | An absolute timestamp.
    SinceTime UTCTime
  | -- | So many units before now, e.g. @SinceAgo 2 Days@.
    SinceAgo Integer Unit
  deriving (Eq, Show)

-- | The units a relative time can be given in.
data Unit
  = Seconds
  | Minutes
  | Hours
  | Days
  | Weeks
  | Months
  | Years
  deriving (Eq, Show)

-- | Parse a @--since@ argument.
--
-- Accepted forms are an ISO 8601 timestamp (@2026-08-01T12:00:00Z@), a plain
-- day (@2026-08-01@, meaning midnight UTC), or an amount of time before now
-- (@2 days@, @1 week@, @6 months@, @3w@), optionally followed by @ago@.
parseSince :: String -> Either String Since
parseSince input =
  case iso8601ParseM trimmed of
    Just t -> Right (SinceTime t)
    Nothing -> case iso8601ParseM trimmed of
      Just d -> Right (SinceTime (UTCTime d 0))
      Nothing -> relative
  where
    trimmed = trim input

    relative = do
      let lowered = map toLower trimmed
          body = trim (fromMaybe lowered (stripSuffix "ago" lowered))
          (digits, rest) = span isDigit body
      amount <-
        if null digits
          then Left problem
          else Right (read digits :: Integer)
      unit <- maybe (Left problem) Right (parseUnit (trim rest))
      pure (SinceAgo amount unit)

    problem =
      "not a timestamp or a relative time: "
        <> input
        <> " (expected e.g. 2026-08-01, 2026-08-01T12:00:00Z, or \"2 weeks\")"

    fromMaybe d = maybe d id

parseUnit :: String -> Maybe Unit
parseUnit u = lookup (dropPlural u) table
  where
    dropPlural s = maybe s id (stripSuffix "s" s)

    table =
      [ ("sec", Seconds)
      , ("second", Seconds)
      , ("min", Minutes)
      , ("minute", Minutes)
      , ("h", Hours)
      , ("hr", Hours)
      , ("hour", Hours)
      , ("d", Days)
      , ("day", Days)
      , ("w", Weeks)
      , ("week", Weeks)
      , ("m", Months)
      , ("month", Months)
      , ("y", Years)
      , ("yr", Years)
      , ("year", Years)
      ]

-- | Turn a 'Since' into an absolute time, given what time it is now.
--
-- Months and years are counted on the calendar rather than as a fixed number
-- of seconds, so @6 months@ back from the 31st lands on the last day of the
-- target month rather than drifting.
resolveSince :: UTCTime -> Since -> UTCTime
resolveSince _ (SinceTime t) = t
resolveSince now (SinceAgo n unit) =
  case unit of
    Seconds -> shift 1
    Minutes -> shift 60
    Hours -> shift 3600
    Days -> shift nominalDay
    Weeks -> shift (7 * nominalDay)
    Months -> onDay (addGregorianMonthsClip (negate n))
    Years -> onDay (addGregorianYearsClip (negate n))
  where
    shift scale = addUTCTime (negate (fromInteger n) * scale) now
    onDay f = now {utctDay = f (utctDay now)}

trim :: String -> String
trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

stripSuffix :: String -> String -> Maybe String
stripSuffix suffix s = reverse <$> stripPrefix (reverse suffix) (reverse s)
