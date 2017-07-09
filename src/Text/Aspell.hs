{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | A pipe-based interface to Aspell.
--
-- This interface is beneficial when dynamic linking against the Aspell
-- library would be undesirable, e.g., for binary portability reasons.
--
-- This implementation is based on the description of the Aspell pipe
-- protocol at
--
-- http://aspell.net/man-html/Through-A-Pipe.html
module Text.Aspell
  ( Aspell
  , AspellResponse(..)
  , Mistake(..)
  , AspellOption(..)
  , startAspell
  , stopAspell
  , askAspell
  , aspellIdentification
  )
where

import qualified Control.Exception as E
import Control.Monad (forM)
import Data.Monoid ((<>))
import Data.Maybe (fromJust)
import Text.Read (readMaybe)
import System.IO (Handle, hFlush)
import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified System.Process as P

-- | A handle to a running Aspell instance.
data Aspell =
    Aspell { aspellProcessHandle  :: P.ProcessHandle
           , aspellStdin          :: Handle
           , aspellStdout         :: Handle
           , aspellIdentification :: T.Text
           }

instance Show Aspell where
    show as = mconcat [ "Aspell<"
                      , T.unpack (aspellIdentification as)
                      , ">"
                      ]

-- | The kind of responses we can get from Aspell.
data AspellResponse =
    AllCorrect
    -- ^ The input had no spelling mistakes.
    | Mistakes [Mistake]
    -- ^ The input had the specified mistakes.
    deriving (Eq, Show)

-- | A spelling mistake.
data Mistake =
    Mistake { mistakeWord         :: T.Text
            -- ^ The original word in misspelled form.
            , mistakeNearMisses   :: Int
            -- ^ The number of alternative correct spellings that were
            -- counted.
            , mistakeOffset       :: Int
            -- ^ The offset, starting at zero, in the original input
            -- where this misspelling occurred.
            , mistakeAlternatives :: [T.Text]
            -- ^ The correct spelling alternatives.
            }
            deriving (Show, Eq)

-- | An Aspell option.
data AspellOption =
    UseDictionary T.Text
    -- ^ Use the specified dictionary (see aspell -d).
    deriving (Show, Eq)

-- | Start Aspell with the specified options. Returns either an error
-- message on failure or an Aspell handle on success.
startAspell :: [AspellOption] -> IO (Either String Aspell)
startAspell options = tryConvert $ do
    let proc = (P.proc "aspell" ("-a" : (concat $ optionToArgs <$> options)))
               { P.std_in = P.CreatePipe
               , P.std_out = P.CreatePipe
               , P.std_err = P.NoStream
               }

    (Just inH, Just outH, Nothing, ph) <- P.createProcess proc
    ident <- T.hGetLine outH

    let as = Aspell { aspellProcessHandle  = ph
                    , aspellStdin          = inH
                    , aspellStdout         = outH
                    , aspellIdentification = ident
                    }

    -- Enable terse mode with aspell to improve performance.
    T.hPutStrLn inH "!"

    return as

optionToArgs :: AspellOption -> [String]
optionToArgs (UseDictionary d) = ["-d", T.unpack d]

-- | Stop a running Aspell instance.
stopAspell :: Aspell -> IO ()
stopAspell = P.terminateProcess . aspellProcessHandle

-- | Submit user input to Aspell for spell-checking. Returns an
-- AspellResponse for each line of user input.
askAspell :: Aspell -> T.Text -> IO [AspellResponse]
askAspell as t = do
    -- Send the user's input. Prefix with "^" to ensure that the line is
    -- checked even if it contains metacharacters.
    forM (T.lines t) $ \theLine -> do
        T.hPutStrLn (aspellStdin as) ("^" <> theLine)
        hFlush (aspellStdin as)

        -- Read lines until we get an empty one, which indicates that aspell
        -- is done with the request.
        resultLines <- readLinesUntil (aspellStdout as) T.null

        case resultLines of
            [] -> return AllCorrect
            _ -> return $ Mistakes $ parseMistake <$> resultLines

parseMistake :: T.Text -> Mistake
parseMistake t
    | "&" `T.isPrefixOf` t = parseWithAlternatives t
    | "#" `T.isPrefixOf` t = parseWithoutAlternatives t

parseWithAlternatives :: T.Text -> Mistake
parseWithAlternatives t =
    let (header, altsWithColon) = T.breakOn ": " t
        altsStr = T.drop 2 altsWithColon
        ["&", orig, nearMissesStr, offsetStr] = T.words header
        alts = T.splitOn ", " altsStr
        offset = fromJust $ readMaybe $ T.unpack offsetStr
        nearMisses = fromJust $ readMaybe $ T.unpack nearMissesStr
    in Mistake { mistakeWord = orig
               , mistakeNearMisses = nearMisses
               -- Aspell's offset starts at 1 here because of the "^"
               -- we included in the input. Here we adjust the offset
               -- so that it's relative to the beginning of the user's
               -- input, not our protocol input.
               , mistakeOffset = offset - 1
               , mistakeAlternatives = alts
               }

parseWithoutAlternatives :: T.Text -> Mistake
parseWithoutAlternatives t =
    let ["#", orig, offsetStr] = T.words t
        offset = fromJust $ readMaybe $ T.unpack offsetStr
    in Mistake { mistakeWord = orig
               , mistakeNearMisses = 0
               , mistakeOffset = offset
               , mistakeAlternatives = []
               }

readLinesUntil :: Handle -> (T.Text -> Bool) -> IO [T.Text]
readLinesUntil h f = do
    line <- T.hGetLine h
    case f line of
        True -> return []
        False -> do
            rest <- readLinesUntil h f
            return $ line : rest

tryConvert :: IO a -> IO (Either String a)
tryConvert act = do
    result <- E.try act
    return $ either (Left . showException) Right result

showException :: E.SomeException -> String
showException = show
