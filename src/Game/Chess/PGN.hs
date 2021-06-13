{-# LANGUAGE GADTs #-}
{-|
Module      : Game.Chess.PGN
Description : Portable Game Notation
Copyright   : (c) Mario Lang, 2021
License     : BSD3
Maintainer  : mlang@blind.guru
Stability   : experimental

A PGN file consists of a list of games.
Each game consists of a tag list, the outcome, and a forest of rosetrees.
-}
module Game.Chess.PGN (
  readPGNFile, gameFromForest, pgnForest, PGN(..), Game(..), Outcome(..), PlyData(..)
, pgn
, hPutPGN, pgnDoc, RAVOrder, breadthFirst, depthFirst, gameDoc
, weightedForest
) where

import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Bifunctor
import           Data.ByteString.Char8                 (ByteString)
import qualified Data.ByteString.Char8                 as BS
import           Data.Char
import           Data.Foldable
import           Data.Functor
import           Data.List
import           Data.Maybe
import           Data.Ord
import           Data.Ratio
import           Data.Text                             (Text)
import qualified Data.Text                             as T
import           Data.Text.Prettyprint.Doc             hiding (space)
import           Data.Text.Prettyprint.Doc.Render.Text
import           Data.Tree
import           Data.Void
import           Data.Word
import           Game.Chess
import           Game.Chess.SAN
import           System.IO
import           Text.Megaparsec
import           Text.Megaparsec.Byte
import qualified Text.Megaparsec.Byte.Lexer            as L

gameFromForest :: [(ByteString, Text)] -> Forest Ply -> Outcome -> Game
gameFromForest tags forest o = (("Result", r):tags, (o, (fmap . fmap) f forest)) where
  f pl = PlyData [] pl []
  r = case o of
    Win White -> "1-0"
    Win Black -> "0-1"
    Draw      -> "1/2-1/2"
    Undecided -> "*"

newtype PGN = PGN [Game] deriving (Eq, Monoid, Semigroup)
type Game = ([(ByteString, Text)], (Outcome, Forest PlyData))
data Outcome = Win Color
             | Draw
             | Undecided
             deriving (Eq, Show)

pgnForest :: PGN -> Forest Ply
pgnForest (PGN gs) = merge $ concatMap ((fmap . fmap) pgnPly . snd . snd) gs

merge :: Eq a => Forest a -> Forest a
merge = foldl mergeTree [] where
  merge' l r = l { subForest = foldl mergeTree (subForest l) (subForest r) }
  mergeTree [] y = [y]
  mergeTree (x:xs) y
    | rootLabel x == rootLabel y = x `merge'` y : xs
    | otherwise = x : xs `mergeTree` y


instance Ord Outcome where
  Win _ `compare` Win _         = EQ
  Win _ `compare` _             = GT
  _ `compare` Win _             = LT
  Draw `compare` Draw           = EQ
  Draw `compare` _              = GT
  _ `compare` Draw              = LT
  Undecided `compare` Undecided = EQ

instance Pretty Outcome where
  pretty (Win White) = "1-0"
  pretty (Win Black) = "0-1"
  pretty Draw        = "1/2-1/2"
  pretty Undecided   = "*"

data PlyData = PlyData {
  prefixNAG :: ![Int]
, pgnPly    :: !Ply
, suffixNAG :: ![Int]
} deriving (Eq, Show)

readPGNFile :: MonadIO m => FilePath -> m (Either String PGN)
readPGNFile fp = liftIO $ first errorBundlePretty . parse pgn fp <$> BS.readFile fp

hPutPGN :: Handle -> RAVOrder (Doc ann) -> PGN -> IO ()
hPutPGN h ro (PGN games) = for_ games $ \g -> do
  hPutDoc h $ gameDoc ro g
  hPutStrLn h ""

type Parser = Parsec Void ByteString

spaceConsumer :: Parser ()
spaceConsumer = L.space
  space1 (L.skipLineComment ";") (L.skipBlockComment "{" "}")

lexeme :: Parser a -> Parser a
lexeme = L.lexeme spaceConsumer

eog :: Parser Outcome
eog = lexeme $  string "1-0" $> Win White
            <|> string "0-1" $> Win Black
            <|> string "1/2-1/2" $> Draw
            <|> string "*" $> Undecided

sym :: Parser ByteString
sym = lexeme . fmap fst . match $ do
  void alphaNumChar
  many $ alphaNumChar <|> oneOf [35,43,45,58,61,95]

periodChar, quoteChar, backslashChar, dollarChar :: Word8
periodChar    = fromIntegral $ ord '.'
quoteChar     = fromIntegral $ ord '"'
backslashChar = fromIntegral $ ord '\\'
dollarChar    = fromIntegral $ ord '$'

lbracketP, rbracketP, lparenP, rparenP :: Parser ()
lbracketP = void . lexeme . single . fromIntegral $ ord '['
rbracketP = void . lexeme . single . fromIntegral $ ord ']'
lparenP   = void . lexeme . single . fromIntegral $ ord '('
rparenP   = void . lexeme . single . fromIntegral $ ord ')'

nag :: Parser Int
nag = lexeme $  single dollarChar *> L.decimal
            <|> string "!!" $> 3
            <|> string "??" $> 4
            <|> string "!?" $> 5
            <|> string "?!" $> 6
            <|> string "!"  $> 1
            <|> string "?"  $> 2

tagPair :: Parser (ByteString, Text)
tagPair = lexeme $ do
  lbracketP
  k <- sym
  v <- str
  rbracketP
  pure (k, v)

tagList :: Parser [(ByteString, Text)]
tagList = many tagPair

movetext :: Position -> Parser (Outcome, Forest PlyData)
movetext pos = (,[]) <$> eog <|> main pos where
  main p = ply p >>= \(m, n) -> fmap n <$> movetext (unsafeDoPly p m)
  var p = ply p >>= \(m, n) -> n <$> (rparenP $> [] <|> var (unsafeDoPly p m))
  ply p = do
    pnags <- many nag
    validateMoveNumber p
    m <- lexeme $ relaxedSAN p
    snags <- many nag
    rav <- concat <$> many (lparenP *> var p)
    pure (m, \xs -> Node (PlyData pnags m snags) xs:rav)
  validateMoveNumber p =
    optional (lexeme $ L.decimal <* space <* many (single periodChar)) >>= \case
      Just n | moveNumber p /= n ->
        fail $ "Invalid move number: " <> show n <> " /= " <> show (moveNumber p)
      _ -> pure ()

pgn :: Parser PGN
pgn = spaceConsumer *> fmap PGN (many game) <* spaceConsumer <* eof

game :: Parser Game
game = do
  tl <- tagList
  pos <- case lookup "FEN" tl of
    Nothing -> pure startpos
    Just fen -> case fromFEN (T.unpack fen) of
      Just p  -> pure p
      Nothing -> fail "Invalid FEN"
  (tl,) <$> movetext pos

str :: Parser Text
str = p <?> "string" where
  p = fmap (T.pack . fmap (chr . fromEnum)) $ single quoteChar *> many ch <* single quoteChar
  ch = single backslashChar *> (  single backslashChar $> backslashChar
                              <|> single quoteChar $> quoteChar
                               )
    <|> anySingleBut quoteChar

type RAVOrder a = (Forest PlyData -> a) -> Forest PlyData -> [a]

breadthFirst, depthFirst :: RAVOrder a
breadthFirst _ [] = []
breadthFirst f ts = pure $ f ts
depthFirst f = fmap $ f . pure

pgnDoc :: RAVOrder (Doc ann) -> PGN -> Doc ann
pgnDoc ro (PGN games) = vsep $ gameDoc ro <$> games

gameDoc :: RAVOrder (Doc ann) -> Game -> Doc ann
gameDoc ro (tl, mt)
  | null tl = moveDoc ro pos mt
  | otherwise = tagsDoc tl <> line <> line <> moveDoc ro pos mt
 where
  pos | Just fen <- lookup "FEN" tl = fromJust $ fromFEN (T.unpack fen)
      | otherwise = startpos

tagsDoc :: [(ByteString, Text)] -> Doc ann
tagsDoc = fuse Shallow . vsep . fmap tagpair where
  tagpair (k, esc -> v) = brackets $ pretty (BS.unpack k) <+> dquotes (pretty v)
  esc = T.concatMap e where
    e '\\' = T.pack "\\\\"
    e '"'  = T.pack "\\\""
    e c    = T.singleton c

moveDoc :: RAVOrder (Doc ann) -> Position -> (Outcome, Forest PlyData) -> Doc ann
moveDoc ro p (o,f) = fillSep (go p True f <> [pretty o]) <> line where
  go _ _ [] = []
  go pos pmn (t:ts)
    | color pos == White || pmn
    = pnag <> (mn:san:snag) <> rav <> go pos' (not . null $ rav) (subForest t)
    | otherwise
    = pnag <> (san:snag) <> rav <> go pos' (not . null $ rav) (subForest t)
   where
    pl = pgnPly . rootLabel $ t
    san = pretty $ unsafeToSAN pos pl
    pos' = unsafeDoPly pos pl
    pnag = prettynag <$> prefixNAG (rootLabel t)
    mn = pretty (moveNumber pos) <> if color pos == White then "." else "..."
    rav = ro (parens . fillSep . go pos True) ts
    snag = prettynag <$> suffixNAG (rootLabel t)
  prettynag n = "$" <> pretty n

weightedForest :: PGN -> Forest (Rational, Ply)
weightedForest (PGN games) = merge . concatMap rate $ snd <$> filter ok games where
  ok (tags, (o, _)) = isNothing (lookup "FEN" tags) && o /= Undecided
  rate (o, ts) = f startpos <$> trunk ts where
    w c | o == Win c = 1
        | o == Win (opponent c) = -1
        | o == Draw = 1 % 2
        | otherwise = 0
    f pos (Node a ts') = Node (w (color pos), pgnPly a) $
      f (unsafeDoPly pos (pgnPly a)) <$> ts'
  trunk []    = []
  trunk (x:_) = [x { subForest = trunk (subForest x)}]
  merge [] = []
  merge ((Node a ts) : xs) =
      sortOn (Down . fst . rootLabel)
    $ Node (w, snd a) (merge $ ts ++ concatMap subForest good) : merge bad
   where
    (good, bad) = partition (eq a . rootLabel) xs where eq x y = snd x == snd y
    w = fst a + sum (fst . rootLabel <$> good)
