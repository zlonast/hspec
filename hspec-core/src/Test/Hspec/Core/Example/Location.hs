{-# LANGUAGE CPP #-}
{-# OPTIONS_GHC -Wno-missing-signatures #-}
module Test.Hspec.Core.Example.Location (
  Location(..)
, extractLocation

#ifdef TEST
, parseBacktraces
, parseAssertionFailed
, parseCallStack
, parseLocation
, parseSourceSpan

, workaroundForIssue19236
#endif
) where

import           Prelude ()
import           Test.Hspec.Core.Compat

import           Data.Char
import           GHC.IO.Exception

#if MIN_VERSION_base(4,21,0)
import           Control.Exception.Context
#endif

#ifdef mingw32_HOST_OS
import           System.FilePath
#endif

-- | @Location@ is used to represent source locations.
data Location = Location {
  locationFile :: FilePath
, locationLine :: Int
, locationColumn :: Int
} deriving (Eq, Show, Read)

extractLocation :: SomeException -> Maybe Location
extractLocation e =
      locationFromErrorCall e
  <|> locationFromPatternMatchFail e
  <|> locationFromRecConError e
  <|> locationFromIOException e
  <|> locationFromNoMethodError e
#if !MIN_VERSION_base(4,21,0)
  <|> locationFromAssertionFailed e
#else
  <|> locationFromSomeException e

locationFromSomeException :: SomeException -> Maybe Location
locationFromSomeException = someExceptionContext >>> locationFromExceptionContext

locationFromExceptionContext :: ExceptionContext -> Maybe Location
locationFromExceptionContext = displayExceptionContext >>> parseBacktraces
#endif

_ignoreUnusedWarning = (parseBacktraces, locationFromAssertionFailed)

parseBacktraces :: String -> Maybe Location
parseBacktraces =
      lines
  >>> dropWhile (/= "HasCallStack backtrace:") >>> drop 1
  >>> takeWhile (isPrefixOf "  ")
  >>> parseCallStack

locationFromNoMethodError :: SomeException -> Maybe Location
locationFromNoMethodError e = case fromException e of
  Just (NoMethodError s) -> listToMaybe (words s) >>= parseSourceSpan
  Nothing -> Nothing

locationFromAssertionFailed :: SomeException -> Maybe Location
locationFromAssertionFailed e = case fromException e of
  Just (AssertionFailed loc) -> parseAssertionFailed loc
  Nothing -> Nothing

parseAssertionFailed :: String -> Maybe Location
parseAssertionFailed loc = parseCallStack (lines loc) <|> parseSourceSpan loc

locationFromErrorCall :: SomeException -> Maybe Location
locationFromErrorCall e = case fromException e of
#if MIN_VERSION_base(4,21,0)
  Just (ErrorCall _) -> Nothing
#else
  Just (ErrorCallWithLocation err loc) ->
    parseCallStack (lines loc) <|>
    fromPatternMatchFailureInDoExpression err
#endif
  Nothing -> Nothing

locationFromPatternMatchFail :: SomeException -> Maybe Location
locationFromPatternMatchFail e = case fromException e of
  Just (PatternMatchFail s) -> listToMaybe (words s) >>= parseSourceSpan
  Nothing -> Nothing

locationFromRecConError :: SomeException -> Maybe Location
locationFromRecConError e = case fromException e of
  Just (RecConError s) -> listToMaybe (words s) >>= parseSourceSpan
  Nothing -> Nothing

locationFromIOException :: SomeException -> Maybe Location
locationFromIOException e = case fromException e of
  Just (IOError {ioe_type = UserError, ioe_description = xs}) -> fromPatternMatchFailureInDoExpression xs
  Just _ -> Nothing
  Nothing -> Nothing

fromPatternMatchFailureInDoExpression :: String -> Maybe Location
fromPatternMatchFailureInDoExpression input =
#if MIN_VERSION_base(4,16,0)
  stripPrefix "Pattern match failure in 'do' block at " input >>= parseSourceSpan
#else
  stripPrefix "Pattern match failure in do expression at " input >>= parseSourceSpan
#endif

parseCallStack :: [String] -> Maybe Location
parseCallStack input = case reverse input of
  [] -> Nothing
  line : _ -> findLocation line
  where
    findLocation xs = case xs of
      [] -> Nothing
      _ : ys -> case stripPrefix prefix xs of
        Just zs -> parseLocation (takeWhile (not . isSpace) zs)
        Nothing -> findLocation ys
    prefix = ", called at "

parseLocation :: String -> Maybe Location
parseLocation input = case fmap breakColon (breakColon input) of
  (file, (line, column)) -> mkLocation file <$> readMaybe line <*> readMaybe column

parseSourceSpan :: String -> Maybe Location
parseSourceSpan input = case breakColon input of
  (file, xs) -> (uncurry $ mkLocation file) <$> (tuple <|> colonSeparated)
    where
      lineAndColumn :: String
      lineAndColumn = takeWhile (/= '-') xs

      tuple :: Maybe (Int, Int)
      tuple = readMaybe lineAndColumn

      colonSeparated :: Maybe (Int, Int)
      colonSeparated = case breakColon lineAndColumn of
        (l, c) -> (,) <$> readMaybe l <*> readMaybe c

breakColon :: String -> (String, String)
breakColon = fmap (drop 1) . break (== ':')

mkLocation :: FilePath -> Int -> Int -> Location
mkLocation file line column = Location (workaroundForIssue19236 file) line column

workaroundForIssue19236 :: FilePath -> FilePath -- https://gitlab.haskell.org/ghc/ghc/-/issues/19236
workaroundForIssue19236 =
#ifdef mingw32_HOST_OS
  joinPath . splitDirectories
#else
  id
#endif
