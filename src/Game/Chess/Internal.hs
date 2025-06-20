{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE BinaryLiterals             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DeriveLift                 #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE MultiWayIf                 #-}
{-# LANGUAGE NamedFieldPuns             #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE PatternSynonyms            #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE UnboxedTuples              #-}
{-# LANGUAGE ViewPatterns               #-}
{-|
Module      : Game.Chess
Description : Basic data types and functions related to the game of chess
Copyright   : (c) Mario Lang, 2020
License     : BSD3
Maintainer  : mlang@blind.guru
Stability   : experimental

A small collection of data types and functions to represent Chess positions
and moves including move generation and parsing from external sources.

This module does deliberately not implement
any search or evaluation functionality.  It is intended to be used
to lay the ground for communicating with other programs or players, hence the
package name chessIO.
-}
module Game.Chess.Internal where

import           Control.DeepSeq
import           Control.Lens                     (view)
import           Control.Lens.Iso                 (from)
import           Control.Monad                    (when, guard)
import           Control.Monad.ST
import           Data.Binary
import           Data.Bits                        (Bits (bit, complement, testBit, unsafeShiftL, unsafeShiftR, xor, (.&.), (.|.)),
                                                   FiniteBits (countLeadingZeros, countTrailingZeros))
import           Data.Char                        (chr, ord)
import           Data.Foldable                    (for_)
import           Data.Hashable
import           Data.Ix                          (Ix (inRange))
import           Data.List                        (nub, sortOn)
import           Data.Maybe                       (fromJust, listToMaybe)
import           Data.Ord                         (Down (..))
import           Data.STRef
import           Data.String                      (IsString (..))
import qualified Data.Vector.Generic              as G
import qualified Data.Vector.Generic.Mutable      as M
import           Data.Vector.Unboxed              (MVector, Unbox, Vector,
                                                   unsafeIndex)
import qualified Data.Vector.Unboxed              as Vector
import qualified Data.Vector.Unboxed.Mutable      as VUM
import           Foreign.Storable
import           GHC.Generics                     (Generic)
import           GHC.Stack                        (HasCallStack)
import           Game.Chess.Internal.QuadBitboard (QuadBitboard)
import qualified Game.Chess.Internal.QuadBitboard as QBB
import           Game.Chess.Internal.Square
import           Language.Haskell.TH.Syntax       (Lift)
import           Text.Read                        (readMaybe)

ep :: Word64 -> Word64
ep flags = flags .&. 0x0000ff0000ff0000

{-# INLINE ep #-}

type Bitboard = Word64

testSquare :: Bitboard -> Square -> Bool
testSquare bb (Sq sq) = 1 `unsafeShiftL` sq .&. bb /= 0
{-# INLINE testSquare #-}

capturing :: Position -> Ply -> Maybe PieceType
capturing pos@Position{flags} (plyTarget -> to)
  | ep flags `testSquare` to = Just Pawn
  | otherwise = snd <$> pieceAt pos to

isCapture :: Position -> Ply -> Bool
isCapture Position{qbb, flags} =
  testSquare (QBB.occupied qbb .|. ep flags) . plyTarget

{-# INLINE isCapture #-}

isPawnPush :: Position -> Ply -> Bool
isPawnPush Position{qbb} = testSquare (QBB.pawns qbb) . plySource

{-# INLINE isPawnPush #-}

-- | The starting position as given by the FEN string
--   "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1".
startpos :: Position
startpos = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

instance IsString Position where fromString = fromJust . fromFEN

newtype PieceType = PieceType Int deriving (Eq, Ix, Lift, Ord)

pattern Pawn, Knight, Bishop, Rook, Queen, King :: PieceType
pattern Pawn = PieceType 0
pattern Knight = PieceType 1
pattern Bishop = PieceType 2
pattern Rook = PieceType 3
pattern Queen = PieceType 4
pattern King = PieceType 5

{-# COMPLETE Pawn, Knight, Bishop, Rook, Queen, King :: PieceType #-}

instance Show PieceType where
  show = \case
    Pawn   -> "Pawn"
    Knight -> "Knight"
    Bishop -> "Bishop"
    Rook   -> "Rook"
    Queen  -> "Queen"
    King   -> "King"

data Color = Black | White deriving (Eq, Generic, Ix, Ord, Lift, Show)

instance Binary Color
instance NFData Color
instance Hashable Color

pieceAt :: Position -> Square -> Maybe (Color, PieceType)
pieceAt Position{qbb} sq = case qbb QBB.! sq of
  QBB.NoPiece -> Nothing
  nb          -> Just
    ( if testBit nb 0 then Black else White
    , PieceType . fromIntegral $ nb `div` 2 - 1
    )

opponent :: Color -> Color
opponent White = Black
opponent Black = White

data Position = Position {
  qbb           :: {-# UNPACK #-} !QuadBitboard
, color         :: !Color
  -- ^ active color
, flags         :: {-# UNPACK #-} !Word64
, halfMoveClock :: {-# UNPACK #-} !Int
, moveNumber    :: {-# UNPACK #-} !Int
  -- ^ number of the full move
} deriving (Generic, Lift)

instance Binary Position
instance NFData Position

-- Article 9.2 states that a position is considered
-- identical to another if the same player is on move, the same types of
-- pieces of the same colors occupy the same squares, and the same moves
-- are available to each player; in particular, each player has the same
-- castling and en passant capturing rights.
instance Eq Position where
  a == b = qbb a == qbb b && color a == color b && flags a == flags b

instance Ord Position where
  a `compare` b = qbb a `compare` qbb b
             <> color a `compare` color b
             <> flags a `compare` flags b

instance Hashable Position where
  hashWithSalt s Position{qbb, color, flags} = s
    `hashWithSalt` qbb
    `hashWithSalt` color
    `hashWithSalt` flags

repetitions :: [Position] -> Maybe (Int, Position)
repetitions xs = listToMaybe . sortOn (Down . fst) $ f <$> nub xs where
  f x = (length . filter (== x) $ xs, x)

instance Show Position where
  show p = '"' : toFEN p <> ['"']

insufficientMaterial :: Position -> Bool
insufficientMaterial = QBB.insufficientMaterial . qbb

-- | Construct a position from Forsyth-Edwards-Notation.
fromFEN :: String -> Maybe Position
fromFEN fen
  | length parts == 6
  = Position <$> pure (fromString (parts !! 0))
             <*> readColor (parts !! 1)
             <*> readFlags (parts !! 2) (parts !! 3)
             <*> readMaybe (parts !! 4)
             <*> readMaybe (parts !! 5)
  | length parts == 4
  = Position <$> pure (fromString (parts !! 0))
             <*> readColor (parts !! 1)
             <*> readFlags (parts !! 2) (parts !! 3)
             <*> pure 0
             <*> pure 1
  | otherwise = Nothing
 where
  parts = words fen
  readColor "w" = Just White
  readColor "b" = Just Black
  readColor _   = Nothing

  readFlags c e = (.|.) <$> readCst c <*> readEP e where
    readCst "-" = pure 0
    readCst x = go x where
      go ('K':xs) = (crwKs .|.) <$> go xs
      go ('Q':xs) = (crwQs .|.) <$> go xs
      go ('k':xs) = (crbKs .|.) <$> go xs
      go ('q':xs) = (crbQs .|.) <$> go xs
      go []       = pure 0
      go _        = Nothing
    readEP "-" = Just 0
    readEP [f,r]
      | inRange ('a','h') f && (r == '3' || r == '6')
      = Just $ bit ((ord r - ord '1') * 8 + (ord f - ord 'a'))
    readEP _ = Nothing

-- | Convert a position to Forsyth-Edwards-Notation.
toFEN :: Position -> String
toFEN Position{qbb, color, flags, halfMoveClock, moveNumber} = unwords
  [ QBB.toString qbb
  , showColor color
  , showCst (flags `clearMask` epMask)
  , showEP (ep flags)
  , show halfMoveClock
  , show moveNumber
  ]
 where
  showColor White = "w"
  showColor Black = "b"
  showCst x
    | str == "" = "-"
    | otherwise = str
   where
    str = snd . wks . wqs . bks . bqs $ (x, "")
    wks (v, xs) | v `testMask` crwKs = (v, 'K':xs)
                | otherwise          = (v, xs)
    wqs (v, xs) | v `testMask` crwQs = (v, 'Q':xs)
                | otherwise          = (v, xs)
    bks (v, xs) | v `testMask` crbKs = (v, 'k':xs)
                | otherwise          = (v, xs)
    bqs (v, xs) | v `testMask` crbQs = (v, 'q':xs)
                | otherwise          = (v, xs)
  showEP 0 = "-"
  showEP x = toCoord . Sq . bitScanForward $ x

occupiedBy :: Color -> QuadBitboard -> Bitboard
occupiedBy White = QBB.white
occupiedBy Black = QBB.black

occupied :: QuadBitboard -> Bitboard
occupied = QBB.occupied

bitScanForward, bitScanReverse :: Bitboard -> Int
bitScanForward = countTrailingZeros
bitScanReverse = (63 -) . countLeadingZeros

{-# INLINE bitScanForward #-}
{-# INLINE bitScanReverse #-}

newtype Ply = Ply { unPly :: Word16 } deriving (Binary, Eq, Hashable, Ord, Lift, Storable)

instance Show Ply where
  show (unpack -> (f, t, p)) = "move " <> show f <> " " <> show t <> p' where
    p' = case p of
      Just piece -> " `promoteTo` " <> show piece
      Nothing    -> ""

newtype instance MVector s Ply = MV_Ply (MVector s Word16)
newtype instance Vector    Ply = V_Ply (Vector Word16)

instance M.MVector MVector Ply where
  basicLength (MV_Ply v) = M.basicLength v
  basicUnsafeSlice i n (MV_Ply v) = MV_Ply $ M.basicUnsafeSlice i n v
  basicOverlaps (MV_Ply v1) (MV_Ply v2) = M.basicOverlaps v1 v2
  basicUnsafeNew n = MV_Ply <$> M.basicUnsafeNew n
  basicInitialize (MV_Ply v) = M.basicInitialize v
  basicUnsafeReplicate n (Ply pl) = MV_Ply <$> M.basicUnsafeReplicate n pl
  basicUnsafeRead (MV_Ply v) i = Ply <$> M.basicUnsafeRead v i
  basicUnsafeWrite (MV_Ply v) i (Ply pl) = M.basicUnsafeWrite v i pl
  basicClear (MV_Ply v) = M.basicClear v
  basicSet (MV_Ply v) (Ply pl) = M.basicSet v pl
  basicUnsafeCopy (MV_Ply v1) (MV_Ply v2) = M.basicUnsafeCopy v1 v2
  basicUnsafeMove (MV_Ply v1) (MV_Ply v2) = M.basicUnsafeMove v1 v2
  basicUnsafeGrow (MV_Ply v) n = MV_Ply <$> M.basicUnsafeGrow v n

instance G.Vector Vector Ply where
  {-# INLINE basicUnsafeIndexM #-}
  basicUnsafeFreeze (MV_Ply v) = V_Ply <$> G.basicUnsafeFreeze v
  basicUnsafeThaw (V_Ply v) = MV_Ply <$> G.basicUnsafeThaw v
  basicLength (V_Ply v) = G.basicLength v
  basicUnsafeSlice i n (V_Ply v) = V_Ply $ G.basicUnsafeSlice  i n v
  basicUnsafeIndexM (V_Ply v) i = Ply <$> G.basicUnsafeIndexM v i
  basicUnsafeCopy (MV_Ply mv) (V_Ply v) = G.basicUnsafeCopy mv v
  elemseq _ pl z = G.elemseq (undefined :: Vector a) pl z

instance Unbox Ply

move :: Square -> Square -> Ply
move (Sq src) (Sq dst) =
  Ply $ fromIntegral dst .|. fromIntegral src `unsafeShiftL` 6

promoteTo :: Ply -> PieceType -> Ply
promoteTo (Ply x) = Ply . set where
  set Pawn          = x
  set King          = x
  set (PieceType v) = x .&. 0xfff .|. fromIntegral (v `unsafeShiftL` 12)

plySource, plyTarget :: Ply -> Square
plySource (Ply x) = Sq $ fromIntegral ((x `unsafeShiftR` 6) .&. 0b111111)
plyTarget (Ply x) = Sq $ fromIntegral (x .&. 0b111111)

plyPromotion :: Ply -> Maybe PieceType
plyPromotion (Ply x) = case fromIntegral $ (x `unsafeShiftR` 12) .&. 0b111 of
  0 -> Nothing
  n -> Just . PieceType $ n

unpack :: Ply -> (Square, Square, Maybe PieceType)
unpack pl = ( plySource pl, plyTarget pl, plyPromotion pl)

-- | Parse a move in the format used by the Universal Chess Interface protocol.
fromUCI :: Position -> String -> Maybe Ply
fromUCI pos (fmap (splitAt 2) . splitAt 2 -> (src, (dst, promo)))
  | null promo
  = move <$> readCoord src <*> readCoord dst >>= relativeTo pos
  | otherwise
  = (\f t p -> move f t `promoteTo` p) <$> readCoord src
                                       <*> readCoord dst
                                       <*> readPromo promo
      >>= relativeTo pos
 where
  readCoord [f,r]
    | inRange ('a','h') f && inRange ('1','8') r
    = Just . view (from rankFile) $ (mkRank $ ord r - ord '1',  mkFile $ ord f - ord 'a')
  readCoord _ = Nothing
  readPromo "q" = Just Queen
  readPromo "r" = Just Rook
  readPromo "b" = Just Bishop
  readPromo "n" = Just Knight
  readPromo _   = Nothing

-- | Convert a move to the format used by the Universal Chess Interface protocol.
toUCI :: Ply -> String
toUCI (unpack -> (src, dst, promo)) = coord src <> coord dst <> p where
  coord x = let (r,f) = view rankFile x in
            chr (unFile f + ord 'a') : [chr (unRank r + ord '1')]
  p = case promo of
    Just Queen  -> "q"
    Just Rook   -> "r"
    Just Bishop -> "b"
    Just Knight -> "n"
    _           -> ""

-- | Castling in the UCI format can sometimes be represented as king capturing
-- its own rook. UCI specifies this for Chess960, but e.g. Lichess seems to do
-- this even for normal, non-960 variants.
--
-- So when a move seems like it's illegal, we check if it's just a different
-- representation of castling.
correctUciCastle :: Position -> Ply -> Maybe Ply
correctUciCastle pos m = do
  guard $ pieceAt pos (plySource m) == Just (color pos, King)
  case (plySource m, plyTarget m) of
    (E1, H1) -> Just wKscm
    (E1, A1) -> Just wQscm
    (E8, H8) -> Just bKscm
    (E8, A8) -> Just bQscm
    _        -> Nothing

-- | Validate that a certain move is legal in the given position.
relativeTo :: Position -> Ply -> Maybe Ply
relativeTo pos m | m `Vector.elem` legalPlies' pos = Just m
                 | Just m' <- correctUciCastle pos m, m' `Vector.elem` legalPlies' pos = Just m'
                 | otherwise = Nothing

shiftN, shiftNN, shiftNNE, shiftNE, shiftENE, shiftE, shiftESE, shiftSE, shiftSSE, shiftS, shiftSS, shiftSSW, shiftSW, shiftWSW, shiftW, shiftWNW, shiftNW, shiftNNW :: Bitboard -> Bitboard
shiftN   w = w `unsafeShiftL` 8
shiftNN   w = w `unsafeShiftL` 16
shiftNNE w = w `unsafeShiftL` 17 .&. notAFile
shiftNE  w = w `unsafeShiftL` 9 .&. notAFile
shiftENE w = w `unsafeShiftL` 10 .&. notABFile
shiftE   w = w `unsafeShiftL` 1 .&. notAFile
shiftESE w = w `unsafeShiftR` 6 .&. notABFile
shiftSE  w = w `unsafeShiftR` 7 .&. notAFile
shiftSSE w = w `unsafeShiftR` 15 .&. notAFile
shiftS   w = w `unsafeShiftR` 8
shiftSS   w = w `unsafeShiftR` 16
shiftSSW w = w `unsafeShiftR` 17 .&. notHFile
shiftSW  w = w `unsafeShiftR` 9 .&. notHFile
shiftWSW w = w `unsafeShiftR` 10 .&. notGHFile
shiftW   w = w `unsafeShiftR` 1 .&. notHFile
shiftWNW w = w `unsafeShiftL` 6 .&. notGHFile
shiftNW  w = w `unsafeShiftL` 7 .&. notHFile
shiftNNW w = w `unsafeShiftL` 15 .&. notHFile

{-# INLINE shiftN #-}
{-# INLINE shiftNN #-}
{-# INLINE shiftS #-}
{-# INLINE shiftSS #-}

-- | Apply a move to the given position.
--
-- This function checks if the move is actually legal and throws and error
-- if it isn't.  See 'unsafeDoPly' for a version that omits the legality check.
doPly :: HasCallStack => Position -> Ply -> Position
doPly p m
  | m `Vector.elem` legalPlies' p = unsafeDoPly p m
  | otherwise        = error "Game.Chess.doPly: Illegal move"

-- | An unsafe version of 'doPly'.  Only use this if you are sure the given move
-- can be applied to the position.  This is useful if the move has been generated
-- by the 'legalPlies' function.
unsafeDoPly :: Position -> Ply -> Position
unsafeDoPly pos@Position{color, halfMoveClock, moveNumber} m =
  (unsafeDoPly' pos m)
  { color = opponent color
  , halfMoveClock = if isCapture pos m || isPawnPush pos m
                    then 0
                    else halfMoveClock + 1
  , moveNumber = if color == Black
                 then moveNumber + 1
                 else moveNumber
  }

unsafeDoPly' :: Position -> Ply -> Position
unsafeDoPly' pos@Position{qbb, flags} m@(unpack -> (src, dst, promo))
  | m == wKscm && flags `testMask` crwKs
  = pos { qbb = qbb <> QBB.whiteKingsideCastle
        , flags = flags `clearMask` (rank1 .|. epMask)
        }
  | m == wQscm && flags `testMask` crwQs
  = pos { qbb = qbb <> QBB.whiteQueensideCastle
        , flags = flags `clearMask` (rank1 .|. epMask)
        }
  | m == bKscm && flags `testMask` crbKs
  = pos { qbb = qbb <> QBB.blackKingsideCastle
        , flags = flags `clearMask` (rank8 .|. epMask)
        }
  | m == bQscm && flags `testMask` crbQs
  = pos { qbb = qbb <> QBB.blackQueensideCastle
        , flags = flags `clearMask` (rank8 .|. epMask)
        }
  | Just piece <- promo
  = case color pos of
      White -> case piece of
        Queen -> pos { qbb = QBB.whitePromotion qbb src dst QBB.WhiteQueen
                     , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                     }
        Rook  -> pos { qbb = QBB.whitePromotion qbb src dst QBB.WhiteRook
                     , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                     }
        Bishop -> pos { qbb = QBB.whitePromotion qbb src dst QBB.WhiteBishop
                      , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                      }
        Knight -> pos { qbb = QBB.whitePromotion qbb src dst QBB.WhiteKnight
                      , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                      }
        _ -> error "Impossible: White tried to promote to Pawn"
      Black -> case piece of
        Queen -> pos { qbb = QBB.blackPromotion qbb src dst QBB.BlackQueen
                     , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                     }
        Rook   -> pos { qbb = QBB.blackPromotion qbb src dst QBB.BlackRook
                      , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                      }
        Bishop -> pos { qbb = QBB.blackPromotion qbb src dst QBB.BlackBishop
                      , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                      }
        Knight -> pos { qbb = QBB.blackPromotion qbb src dst QBB.BlackKnight
                      , flags = flags `clearMask` (epMask .|. bit (unSquare dst))
                      }
        _ -> error "Impossible: Black tried to promote to Pawn"
  | pawns `testMask` fromMask
  , ep flags `testMask` toMask
  = pos { qbb = qbb <> QBB.enPassant src dst
        , flags = flags `clearMask` toMask
        }
  | otherwise
  = pos { qbb = QBB.move qbb src dst
        , flags = flags `clearMask` (epMask .|. mask) .|. dpp
        }
 where
  !fromMask = 1 `unsafeShiftL` unSquare src
  !toMask = 1 `unsafeShiftL` unSquare dst
  !mask = fromMask .|. toMask
  !pawns = QBB.pawns qbb
  !dpp
    | (pawns .&. (rank2 .|. rank7)) `testMask` fromMask
    = if | shiftNN fromMask == toMask -> shiftN fromMask
         | shiftSS fromMask == toMask -> shiftS fromMask
         | otherwise                  -> 0
    | otherwise = 0

forBits :: Word64 -> (Int -> ST s ()) -> ST s ()
forBits w f = go w where
  go 0 = pure ()
  go n = f (countTrailingZeros n) *> go (n .&. (n - 1))
{-# INLINE forBits #-}

-- | Generate a list of possible moves for the given position.
legalPlies :: Position -> [Ply]
legalPlies = Vector.toList . legalPlies'

legalPlies' :: Position -> Vector Ply
legalPlies' pos@Position{color, qbb, flags} = runST $ do
  v <- VUM.new 100
  i <- newSTRef 0
  let add pl
        | not $ inCheck color (unsafeDoPly' pos pl) = do
          i' <- readSTRef i
          VUM.unsafeWrite v i' pl
          modifySTRef' i (+ 1)
        | otherwise = pure ()
      {-# INLINE add #-}

  case color of
    White -> do
      let !us = QBB.white qbb
          !them = QBB.black qbb
          !notUs = complement us
          !occ = us .|. them
          !notOcc = complement occ

      -- Pawn
      let !wPawns = QBB.wPawns qbb
      let !singlePushTargets = shiftN wPawns .&. notOcc
      let !doublePushTargets = shiftN singlePushTargets .&. notOcc .&. rank4
      let !captureTargets = them .|. ep flags
      let !eastCaptureTargets = shiftNE wPawns .&. captureTargets
      let !westCaptureTargets = shiftNW wPawns .&. captureTargets
      let pawn s d
            | d >= 56
            = let pl = move (Sq s) (Sq d)
              in for_ [Queen, Rook, Bishop, Knight] $ \p ->
                   add $ pl `promoteTo` p
            | otherwise
            = add $ move (Sq s) (Sq d)
      forBits westCaptureTargets $ \dst -> do
        pawn (dst - 7) dst
      forBits eastCaptureTargets $ \dst -> do
        pawn (dst - 9) dst
      forBits singlePushTargets $ \dst ->
        pawn (dst - 8) dst
      forBits doublePushTargets $ \dst ->
        add $ move (Sq $ dst - 16) (Sq dst)

      piecePlies (QBB.wKnights qbb)
                 (QBB.wBishops qbb)
                 (QBB.wRooks qbb)
                 (QBB.wQueens qbb)
        occ notUs add

      -- King
      forBits (QBB.wKings qbb) $ \src -> do
        forBits (kingAttacks `unsafeIndex` src .&. notUs) $ \dst -> do
          add $ move (Sq src) (Sq dst)
      when (canWhiteCastleKingside pos occ) $ add wKscm
      when (canWhiteCastleQueenside pos occ) $ add wQscm

    Black -> do
      let !us = QBB.black qbb
          !them = QBB.white qbb
          !notUs = complement us
          !occ = us .|. them
          !notOcc = complement occ

      -- Pawn
      let !bPawns = QBB.bPawns qbb
      let !singlePushTargets = shiftS bPawns .&. notOcc
      let !doublePushTargets = shiftS singlePushTargets .&. notOcc .&. rank5
      let !captureTargets = them .|. ep flags
      let !eastCaptureTargets = shiftSE bPawns .&. captureTargets
      let !westCaptureTargets = shiftSW bPawns .&. captureTargets
      let pawn s d
            | d <= 7
            = let pl = move (Sq s) (Sq d)
              in for_ [Queen, Rook, Bishop, Knight] $ \p ->
                   add $ pl `promoteTo` p
            | otherwise
            = add $ move (Sq s) (Sq d)
      forBits westCaptureTargets $ \dst -> do
        pawn (dst + 9) dst
      forBits eastCaptureTargets $ \dst -> do
        pawn (dst + 7) dst
      forBits singlePushTargets $ \dst ->
        pawn (dst + 8) dst
      forBits doublePushTargets $ \dst ->
        add $ move (Sq $ dst + 16) (Sq dst)

      piecePlies (QBB.bKnights qbb)
                 (QBB.bBishops qbb)
                 (QBB.bRooks qbb)
                 (QBB.bQueens qbb)
        occ notUs add

      -- King
      forBits (QBB.bKings qbb) $ \src -> do
        forBits (kingAttacks `unsafeIndex` src .&. notUs) $ \dst -> do
          add $ move (Sq src) (Sq dst)
      when (canBlackCastleKingside pos occ) $ add bKscm
      when (canBlackCastleQueenside pos occ) $ add bQscm

  Vector.unsafeFreeze . ($ v) . VUM.unsafeSlice 0 =<< readSTRef i

piecePlies :: Bitboard -> Bitboard -> Bitboard -> Bitboard
           -> Bitboard -> Bitboard -> (Ply -> ST s ())
           -> ST s ()
piecePlies !knights !bishops !rooks !queens !occ !notUs add = do
  forBits knights $ \src -> do
    forBits (knightAttacks `unsafeIndex` src .&. notUs) $ \dst -> do
      add $ move (Sq src) (Sq dst)
  forBits bishops $ \src -> do
    forBits (diagonal src occ .&. notUs) $ \dst -> do
      add $ move (Sq src) (Sq dst)
  forBits rooks $ \src -> do
    forBits (orthogonal src occ .&. notUs) $ \dst -> do
      add $ move (Sq src) (Sq dst)
  forBits queens $ \src -> do
    forBits ((orthogonal src occ .|. diagonal src occ) .&. notUs) $ \dst -> do
      add $ move (Sq src) (Sq dst)
{-# INLINE piecePlies #-}

-- | Returns 'True' if 'Color' is in check in the given position.
inCheck :: Color -> Position -> Bool
inCheck White Position{qbb} =
  attackedBy Black qbb (QBB.occupied qbb) (Sq (bitScanForward (QBB.wKings qbb)))
inCheck Black Position{qbb} =
  attackedBy White qbb (QBB.occupied qbb) (Sq (bitScanForward (QBB.bKings qbb)))

{-# INLINE inCheck #-}

data Castle = Kingside | Queenside deriving (Eq, Ix, Ord, Show)

castlingRights :: Position -> [(Color, Castle)]
castlingRights Position{flags} = wks . wqs . bks . bqs $ [] where
  wks xs | flags `testMask` crwKs = (White, Kingside):xs
         | otherwise              = xs
  wqs xs | flags `testMask` crwQs = (White, Queenside):xs
         | otherwise              = xs
  bks xs | flags `testMask` crbKs = (Black, Kingside):xs
         | otherwise              = xs
  bqs xs | flags `testMask` crbQs = (Black, Queenside):xs
         | otherwise              = xs

enPassantSquare :: Position -> Maybe Square
enPassantSquare Position{flags} = case ep flags of
  0 -> Nothing
  x -> Just . Sq . bitScanForward $ x

canCastleKingside, canCastleQueenside :: Position -> Bool
canCastleKingside pos@Position{qbb, color = White} =
  canWhiteCastleKingside pos (occupied qbb)
canCastleKingside pos@Position{qbb, color = Black} =
  canBlackCastleKingside pos (occupied qbb)
canCastleQueenside pos@Position{qbb, color = White} =
  canWhiteCastleQueenside pos (occupied qbb)
canCastleQueenside pos@Position{qbb, color = Black} =
  canBlackCastleQueenside pos (occupied qbb)

canWhiteCastleKingside, canBlackCastleKingside, canWhiteCastleQueenside, canBlackCastleQueenside :: Position -> Word64 -> Bool
canWhiteCastleKingside Position{qbb, flags} !occ =
  flags `testMask` crwKs && occ .&. crwKe == 0 &&
  not (any (attackedBy Black qbb occ) [E1, F1, G1])
canBlackCastleKingside Position{qbb, flags} !occ =
  flags `testMask` crbKs && occ .&. crbKe == 0 &&
  not (any (attackedBy White qbb occ) [E8, F8, G8])
canWhiteCastleQueenside Position{qbb, flags} !occ =
  flags `testMask` crwQs && occ .&. crwQe == 0 &&
  not (any (attackedBy Black qbb occ) [E1, D1, C1])
canBlackCastleQueenside Position{qbb, flags} !occ =
  flags `testMask` crbQs && occ .&. crbQe == 0 &&
  not (any (attackedBy White qbb occ) [E8, D8, C8])

wKscm, wQscm, bKscm, bQscm :: Ply
wKscm = move E1 G1
wQscm = move E1 C1
bKscm = move E8 G8
bQscm = move E8 C8

attackedBy :: Color -> QuadBitboard -> Word64 -> Square -> Bool
attackedBy c !qbb !occ (Sq sq) =
   (  pawnAttacks sq               .&. QBB.pawns qbb
  .|. unsafeIndex knightAttacks sq .&. QBB.knights qbb
  .|. diagonal sq occ              .&. QBB.diagonals qbb
  .|. orthogonal sq occ            .&. QBB.orthogonals qbb
  .|. unsafeIndex kingAttacks sq   .&. QBB.kings qbb
   ) .&. us /= 0
 where
  (# !pawnAttacks, !us #) = case c of
    White -> (# unsafeIndex wPawnAttacks, QBB.white qbb #)
    Black -> (# unsafeIndex bPawnAttacks, QBB.black qbb #)

{-# INLINE attackedBy #-}

attackedByPawn :: Square -> Position -> Bool
attackedByPawn (Sq sq) Position{qbb, color} = case color of
  White -> unsafeIndex wPawnAttacks sq .&. QBB.wPawns qbb /= 0
  Black -> unsafeIndex bPawnAttacks sq .&. QBB.bPawns qbb /= 0

notAFile, notABFile, notGHFile, notHFile, rank1, rank2, rank3, rank4, rank5, rank6, rank7, rank8 :: Word64
notAFile = 0xfefefefefefefefe
notABFile = 0xfcfcfcfcfcfcfcfc
notGHFile = 0x3f3f3f3f3f3f3f3f
notHFile = 0x7f7f7f7f7f7f7f7f
rank1 = 0x00000000000000ff
rank2 = 0x000000000000ff00
rank3 = 0x0000000000ff0000
rank4 = 0x00000000ff000000
rank5 = 0x000000ff00000000
rank6 = 0x0000ff0000000000
rank7 = 0x00ff000000000000
rank8 = 0xff00000000000000

epMask, crwKs, crwQs, crwKe, crwQe, crbKs, crbQs, crbKe, crbQe :: Word64
epMask = rank3 .|. rank6        -- mask for en passant
crwKs  = 0x0000000000000090     -- white: king & rook position for kingside castle
crwQs  = 0x0000000000000011     -- white: king & rook pisition for queenside castle^M
crwKe  = 0x0000000000000060     -- white: empty fields for kingside castle
crwQe  = 0x000000000000000e     -- white: empty fields for queenside castle
crbKs  = 0x9000000000000000     -- black: king & rook position for kingside castle
crbQs  = 0x1100000000000000     -- black: king & rook position for queenside castle^M
crbKe  = 0x6000000000000000     -- black: empty fields for kingside castle
crbQe  = 0x0e00000000000000     -- black: empty fields for queenside castle

kingAttacks, knightAttacks, wPawnAttacks, bPawnAttacks :: Vector Word64
kingAttacks = Vector.generate 64 $ \sq -> let b = bit sq in
  shiftN b .|. shiftNE b .|. shiftE b .|. shiftSE b .|.
  shiftS b .|. shiftSW b .|. shiftW b .|. shiftNW b
knightAttacks = Vector.generate 64 $ \sq -> let b = bit sq in
  shiftNNE b .|. shiftENE b .|.
  shiftESE b .|. shiftSSE b .|.
  shiftSSW b .|. shiftWSW b .|.
  shiftWNW b .|. shiftNNW b
wPawnAttacks = Vector.generate 64 $ \sq -> let b = bit sq in
  shiftSE b .|. shiftSW b
bPawnAttacks = Vector.generate 64 $ \sq -> let b = bit sq in
  shiftNE b .|. shiftNW b

orthogonal, diagonal :: Int -> Bitboard -> Bitboard
orthogonal !sq !occ = mask .&. (up .&. down .|. left .&. right) where
  mask = complement $ unsafeShiftL 1 sq
  occ' = occ .&. mask
  up = unsafeShiftR hFile $ (63 -) $ bitScanForward $
       unsafeShiftL aFile sq .&. (occ' .|. rank8)
  down = unsafeShiftL aFile $ bitScanReverse $
         unsafeShiftR hFile (63 - sq) .&. (occ' .|. rank1)
  right = unsafeShiftR rank8 $ (63 -) $ bitScanForward $
          unsafeShiftL rank1 sq .&. (occ' .|. hFile)
  left = unsafeShiftL rank1 $ bitScanReverse $
         unsafeShiftR rank8 (63 - sq) .&. (occ' .|. aFile)
diagonal !sq !occ = mask .&. (up .&. down .|. left .&. right) where
  mask = complement $ unsafeShiftL 1 sq
  occ' = occ .&. mask
  up = unsafeShiftR a1h8 $ (63 -) $ bitScanForward $
       unsafeShiftL a1h8 sq .&. (occ' .|. rank8 .|. hFile)
  down = unsafeShiftL a1h8 $ bitScanReverse $
         unsafeShiftR a1h8 (63 - sq) .&. (occ' .|. rank1 .|. aFile)
  right = unsafeShiftL h1a8 $ bitScanReverse $
          unsafeShiftR h1a8 (63 - sq) .&. (occ' .|. rank1 .|. hFile)
  left = unsafeShiftR h1a8 $ (63 -) $ bitScanForward $
         unsafeShiftL h1a8 sq .&. (occ' .|. aFile .|. rank8)

aFile, hFile, a1h8, h1a8 :: Bitboard
aFile = 0x0101010101010101
hFile = 0x8080808080808080
a1h8 = 0x8040201008040201
h1a8 = 0x8102040810204081

clearMask :: Bits a => a -> a -> a
clearMask a b = a .&. complement b

testMask :: Bits a => a -> a -> Bool
testMask a b = a .&. b == b

{-# INLINE testMask #-}
