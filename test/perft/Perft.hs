module Main where

import Control.Parallel.Strategies
import Data.Foldable
import Data.Maybe
import Data.Monoid
import Data.Time.Clock
import Data.Traversable
import Game.Chess
import GHC.Generics (Generic)
import System.Directory
import System.Exit
import System.IO

type Depth = Int
type Testsuite = [(Position, [(Depth, PerftResult)])]

main :: IO ()
main = do
  start <- getCurrentTime
  exists <- doesFileExist "test/perft/perftsuite.epd"
  result <- if exists
    then do
      suite <- readTestSuite "test/perft/perftsuite.epd"
      runTestSuite suite
    else do
      fmap (Just . fold) . for [0..6] $ \n -> do
        let r = perft n startpos
        putStrLn $ showResult n r
        hFlush stdout
        pure r
  end <- getCurrentTime
  case result of
    Just PerftResult{nodes} -> putStrLn $
       "nps: " <>
       show (floor (realToFrac (fromIntegral nodes) / realToFrac (diffUTCTime end start)))
    _ -> pure ()
  putStrLn $ "Time: " <> show (diffUTCTime end start)
  exitWith $ if isJust result then ExitSuccess else ExitFailure 1

data PerftResult = PerftResult { nodes :: !Integer } deriving (Eq, Generic, Show)
instance NFData PerftResult

instance Semigroup PerftResult where
  PerftResult n1 <> PerftResult n2 = PerftResult $ n1 + n2

instance Monoid PerftResult where
  mempty = PerftResult 0

showResult :: Depth -> PerftResult -> String
showResult depth PerftResult{nodes} = show depth <> " " <> show nodes

perft :: Depth -> Position -> PerftResult
perft 0 _ = PerftResult 1
perft 1 p = PerftResult . fromIntegral . length $ legalPlies p
perft n p
  | n < 4
  = foldMap (perft (pred n) . unsafeDoPly p) $ legalPlies p
  | otherwise
  = fold . parMap rdeepseq (perft (pred n) . unsafeDoPly p) $ legalPlies p

runTestSuite :: Testsuite -> IO (Maybe PerftResult)
runTestSuite = fmap (getAp . foldMap Ap) . traverse (uncurry (test mempty)) where
  test sum pos ((depth, expected) : more)
    | result == expected
    = do
      putStrLn $ "OK   " <> fen <> " ;D" <> show depth <> " "
              <> show (nodes expected)
      hFlush stdout
      test (sum <> result) pos more
    | otherwise
    = do
      putStrLn $ "FAIL " <> fen <> " ;D" <> show depth <> " "
              <> show (nodes expected) <> " /= " <> show (nodes result)
      pure Nothing
   where result = perft depth pos
         fen = toFEN pos
  test sum _ [] = pure (Just sum)

readTestSuite :: FilePath -> IO Testsuite
readTestSuite fp = do
  epd <- readFile fp
  pure $ fmap readData . (\ws -> (fromJust (fromFEN (unwords $ take 6 ws)), drop 6 ws)) . words <$> lines epd
 where
  readData [] = []
  readData ((';':'D':d):v:xs) = (read d, PerftResult $ read v) : readData xs
  readData _ = error "Failed to parse test suite"
