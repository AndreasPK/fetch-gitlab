{-# LANGUAGE OverloadedStrings #-}

{- | The machinery for lifting shared sub-objects out of a JSON object.

What GitLab sends repeats itself heavily: the same user object arrives once
per note, and a project's notes outnumber its people by thousands to one.
A 'LiftSpec' says which of an object's fields hold such shared objects;
'splitObject' takes them out and 'spliceObject' puts them back.

'splitObject' and 'spliceObject' are inverses, which is what makes lifting
safe: what comes back out of a store is the value that went in, not a best
effort at reassembling one.

Which fields each kind of record lifts — and the tables the lifted objects
land in — is the business of "FetchGitLab.Store.Schema".
-}
module FetchGitLab.Store.Schema.Types (
    LiftSpec (..),
    Lifted (..),
    noLifted,
    splitObject,
    spliceObject,
) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Vector as V

{- | Which of an object's fields are shared with other objects, and so belong
in a table of their own rather than in the object.
-}
data LiftSpec = LiftSpec
    { specUsers :: [Text]
    -- ^ Fields holding a single user.
    , specUserLists :: [Text]
    -- ^ Fields holding an ordered list of users.
    , specMilestone :: Bool
    -- ^ Whether a @milestone@ field is lifted.
    , specLabels :: Bool
    -- ^ Whether a @labels@ field is lifted.
    }

-- | The shared objects taken out of one record or note.
data Lifted = Lifted
    { liftedUsers :: [(Text, Int, Value)]
    {- ^ Field name, position within it, and the user. A field in 'specUsers'
    contributes one entry at position 0.
    -}
    , liftedMilestone :: Maybe Value
    , liftedLabels :: [(Int, Text)]
    -- ^ Position and name, since the order in the JSON is worth keeping.
    , liftedKeys :: [Text]
    {- ^ The keys actually removed, in the order 'spliceObject' should put
    them back. This is what tells an absent field from an empty one: a
    record with no assignees at all and one with @[]@ differ only here.
    -}
    }
    deriving (Eq, Show)

noLifted :: Lifted
noLifted = Lifted [] Nothing [] []

{- | Take the shared objects out of a JSON object.

Returns what is left and what was removed. Fields the object does not have
are not invented, and a field holding @null@ is left where it is rather than
lifted, so that splicing puts back exactly what was there.
-}
splitObject :: LiftSpec -> Value -> (Value, Lifted)
splitObject spec (Object o) = (Object leftover, lifted)
  where
    leftover = foldr (KM.delete . Key.fromText) o (liftedKeys lifted)

    lifted =
        Lifted
            { liftedUsers = singles <> lists
            , liftedMilestone = milestone
            , liftedLabels = labels
            , liftedKeys = keys
            }

    -- A key is only lifted if it holds something of the shape we expect.
    at k = KM.lookup (Key.fromText k) o

    singles =
        [ (k, 0, v)
        | k <- specUsers spec
        , Just v@(Object _) <- [at k]
        ]

    lists =
        [ (k, i, v)
        | k <- specUserLists spec
        , Just (Array xs) <- [at k]
        , (i, v) <- zip [0 ..] (V.toList xs)
        ]

    milestone
        | specMilestone spec, Just v@(Object _) <- at "milestone" = Just v
        | otherwise = Nothing

    labels
        | specLabels spec
        , Just (Array xs) <- at "labels" =
            [(i, t) | (i, String t) <- zip [0 ..] (V.toList xs)]
        | otherwise = []

    keys =
        [k | (k, _, _) <- singles]
            <> [k | k <- specUserLists spec, Just (Array _) <- [at k]]
            <> ["milestone" | Just _ <- [milestone]]
            <> ["labels" | specLabels spec, Just (Array _) <- [at "labels"]]
splitObject _ v = (v, noLifted)

{- | Put back what 'splitObject' took out.

@'spliceObject' spec l . fst . 'splitObject' spec@ is the identity on any
object @splitObject@ produced @l@ from.
-}
spliceObject :: LiftSpec -> Lifted -> Value -> Value
spliceObject spec l (Object o) = Object (foldl put o (liftedKeys l))
  where
    put acc k = case rebuild k of
        Nothing -> acc
        Just v -> KM.insert (Key.fromText k) v acc

    rebuild k
        | k `elem` specUsers spec =
            case [v | (f, _, v) <- liftedUsers l, f == k] of
                (v : _) -> Just v
                [] -> Nothing
        | k `elem` specUserLists spec =
            Just . Array . V.fromList . map snd . sortOn fst $
                [(i, v) | (f, i, v) <- liftedUsers l, f == k]
        | k == "milestone" = liftedMilestone l
        | k == "labels" =
            Just . Array . V.fromList . map (String . snd) . sortOn fst $ liftedLabels l
        | otherwise = Nothing
spliceObject _ _ v = v
