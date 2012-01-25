{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2012.01.25
-- |
-- Module      :  Data.ByteString.Lex.Integral
-- Copyright   :  Copyright (c) 2010--2012 wren ng thornton
-- License     :  BSD3
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  provisional
-- Portability :  Haskell98
--
-- Functions for parsing and producing 'Integral' values from\/to
-- 'ByteString's based on the \"Char8\" encoding. That is, we assume
-- an ASCII-compatible encoding of alphanumeric characters.
----------------------------------------------------------------
module Data.ByteString.Lex.Integral
    (
    -- * Decimal conversions
      readDecimal
    , packDecimal
    -- TODO: asDecimal -- this will be really hard to make efficient...
    -- * Hexadecimal conversions
    , readHexadecimal
    , packHexadecimal
    , asHexadecimal
    -- * Octal conversions
    , readOctal
    , packOctal
    -- TODO: asOctal -- this will be hard to make really efficient...
    ) where

import           Data.ByteString          (ByteString)
import qualified Data.ByteString          as BS
import qualified Data.ByteString.Char8    as BS8 (pack)
import qualified Data.ByteString.Internal as BSI
import qualified Data.ByteString.Unsafe   as BSU
import           Data.Int
import           Data.Word
import           Data.Bits
import           Foreign.Ptr              (Ptr, plusPtr)
import qualified Foreign.ForeignPtr       as FFI (withForeignPtr)
import           Foreign.Storable         (peek, poke)

----------------------------------------------------------------
----- Decimal

-- | Read a positive integral value in ASCII decimal format. Returns
-- @Nothing@ if there is no integer at the beginning of the string,
-- otherwise returns @Just@ the integer read and the remainder of
-- the string.
--
-- The implementation is based on
-- @bytestring-0.9.1.7:Data.ByteString.Char8.readInt@ except we
-- only parse positive ints and do not recognize sign sigils. Sign
-- sigils are better handled by a combinator which reads the sign
-- character and then adjusts the result of this function appropriately.
readDecimal :: (Integral a) => ByteString -> Maybe (a, ByteString)
{-# SPECIALIZE readDecimal ::
    ByteString -> Maybe (Int,     ByteString),
    ByteString -> Maybe (Int8,    ByteString),
    ByteString -> Maybe (Int16,   ByteString),
    ByteString -> Maybe (Int32,   ByteString),
    ByteString -> Maybe (Int64,   ByteString),
    ByteString -> Maybe (Integer, ByteString),
    ByteString -> Maybe (Word,    ByteString),
    ByteString -> Maybe (Word8,   ByteString),
    ByteString -> Maybe (Word16,  ByteString),
    ByteString -> Maybe (Word32,  ByteString),
    ByteString -> Maybe (Word64,  ByteString) #-}
readDecimal = start
    where
    -- This version is near verbatim from 'Data.ByteString.Char8.readInt'.
    -- We do remove the superstrictness by lifting the 'Just' so
    -- it can be returned after seeing the first byte. Do beware
    -- of the scope of 'fromIntegral', we want to avoid unnecessary
    -- 'Integral' operations and do as much as possible in 'Word8'.
    start xs
        | BS.null xs = Nothing
        | otherwise  =
            case BSU.unsafeHead xs of
            w | 0x30 <= w && w <= 0x39 ->
                    Just $ loop (fromIntegral (w - 0x30)) (BSU.unsafeTail xs)
              | otherwise -> Nothing
    
    loop n xs
        | n `seq` xs `seq` False = undefined -- for strictness analysis
        | BS.null xs = (n, BS.empty)         -- not @xs@, to help GC
        | otherwise  =
            case BSU.unsafeHead xs of
            w | 0x30 <= w && w <= 0x39 ->
                    loop (n * 10 + fromIntegral (w - 0x30)) (BSU.unsafeTail xs)
              | otherwise -> (n,xs)

{- TODO:
Benchmark against the implementation
<http://www.mega-nerd.com/erikd/Blog/CodeHacking/Haskell/read_int.html>:

fromIntegral . BS8.foldl' (\i c -> i * 10 + Char.digitToInt c) 0 . BS8.takeWhile Char.isDigit
-}

-- Beware the overflow issues of 'numDigits', noted at bottom.
-- | Convert a positive integer into an (unsigned) ASCII decimal
-- string. Returns @Nothing@ on negative inputs.
packDecimal :: (Integral a) => a -> Maybe ByteString
{-# SPECIALIZE packDecimal ::
    Int     -> Maybe ByteString,
    Int8    -> Maybe ByteString,
    Int16   -> Maybe ByteString,
    Int32   -> Maybe ByteString,
    Int64   -> Maybe ByteString,
    Integer -> Maybe ByteString,
    Word    -> Maybe ByteString,
    Word8   -> Maybe ByteString,
    Word16  -> Maybe ByteString,
    Word32  -> Maybe ByteString,
    Word64  -> Maybe ByteString #-}
packDecimal = start
    where
    start n0
        | n0 < 0    = Nothing
        | otherwise = Just $
            let size = numDigits 10 (toInteger n0)
            in  BSI.unsafeCreate size $ \p0 ->
                    loop n0 (p0 `plusPtr` (size - 1))
    
    loop :: (Integral a) => a -> Ptr Word8 -> IO ()
    loop n p
        | n `seq` p `seq` False = undefined -- for strictness analysis
        | n <= 9    = do
            poke p (0x30 + fromIntegral n)
        | otherwise = do
            -- quotRem == divMod when both @n@ and @b@ are positive,
            -- but 'quotRem' is often faster (for Int it's one machine-op!)
            let (q,r) = n `quotRem` 10
            poke p (0x30 + fromIntegral r)
            loop q (p `plusPtr` negate 1)
{-
-- N.B., this implementation is more obviously correct but much slower.
packDecimal :: (Integral a) => a -> Maybe ByteString
packDecimal = start
    where
    start n0
        | n0 < 0    = Nothing
        | otherwise = Just $ loop n0 BS.empty
    
    loop n xs
        | n `seq` xs `seq` False = undefined -- for strictness analysis
        | n <= 9    = BS.cons (0x30 + fromIntegral n) xs
        | otherwise =
            let (q,r) = n `quotRem` 10
            in loop q (BS.cons (0x30 + fromIntegral r) xs)
-}


----------------------------------------------------------------
----- Hexadecimal

-- | Read a positive integral value in ASCII hexadecimal format.
-- Returns @Nothing@ if there is no integer at the beginning of the
-- string, otherwise returns @Just@ the integer read and the remainder
-- of the string.
--
-- This function does not recognize the various hexadecimal sigils
-- like \"0x\", but because there are so many different variants,
-- those are best handled by helper functions which then use this
-- one for the numerical parsing. This function recognizes both
-- upper-case, lower-case, and mixed-case hexadecimal.
readHexadecimal :: (Integral a) => ByteString -> Maybe (a, ByteString)
{-# SPECIALIZE readHexadecimal ::
    ByteString -> Maybe (Int,     ByteString),
    ByteString -> Maybe (Int8,    ByteString),
    ByteString -> Maybe (Int16,   ByteString),
    ByteString -> Maybe (Int32,   ByteString),
    ByteString -> Maybe (Int64,   ByteString),
    ByteString -> Maybe (Integer, ByteString),
    ByteString -> Maybe (Word,    ByteString),
    ByteString -> Maybe (Word8,   ByteString),
    ByteString -> Maybe (Word16,  ByteString),
    ByteString -> Maybe (Word32,  ByteString),
    ByteString -> Maybe (Word64,  ByteString) #-}
readHexadecimal = start
    where
    -- Beware the urge to make this code prettier, cf 'readDecimal'.
    start xs
        | BS.null xs = Nothing
        | otherwise  =
            case BSU.unsafeHead xs of
            w | 0x30 <= w && w <= 0x39 ->
                    Just $ loop (fromIntegral (w - 0x30))  (BSU.unsafeTail xs)
              | 0x41 <= w && w <= 0x46 ->
                    Just $ loop (fromIntegral (w-0x41+10)) (BSU.unsafeTail xs)
              | 0x61 <= w && w <= 0x66 ->
                    Just $ loop (fromIntegral (w-0x61+10)) (BSU.unsafeTail xs)
              | otherwise -> Nothing
    
    loop n xs
        | n `seq` xs `seq` False = undefined -- for strictness analysis
        | BS.null xs = (n, BS.empty)         -- not @xs@, to help GC
        | otherwise  =
            case BSU.unsafeHead xs of
            w | 0x30 <= w && w <= 0x39 ->
                    loop (n*16 + fromIntegral (w - 0x30))  (BSU.unsafeTail xs)
              | 0x41 <= w && w <= 0x46 ->
                    loop (n*16 + fromIntegral (w-0x41+10)) (BSU.unsafeTail xs)
              | 0x61 <= w && w <= 0x66 ->
                    loop (n*16 + fromIntegral (w-0x61+10)) (BSU.unsafeTail xs)
              | otherwise -> (n,xs)


-- | Convert a positive integer into a lower-case ASCII hexadecimal
-- string. Returns @Nothing@ on negative inputs.
packHexadecimal :: (Integral a) => a -> Maybe ByteString
{-# SPECIALIZE packHexadecimal ::
    Int     -> Maybe ByteString,
    Int8    -> Maybe ByteString,
    Int16   -> Maybe ByteString,
    Int32   -> Maybe ByteString,
    Int64   -> Maybe ByteString,
    Integer -> Maybe ByteString,
    Word    -> Maybe ByteString,
    Word8   -> Maybe ByteString,
    Word16  -> Maybe ByteString,
    Word32  -> Maybe ByteString,
    Word64  -> Maybe ByteString #-}
packHexadecimal = start
    where
    start n0
        | n0 < 0    = Nothing
        | otherwise = Just $
            let size = twoPowerNumDigits 4 (toInteger n0) -- for Bits
            in  BSI.unsafeCreate size $ \p0 ->
                    loop n0 (p0 `plusPtr` (size - 1))
    
    -- TODO: benchmark using @hexDigits@ vs using direct manipulations.
    loop :: (Integral a) => a -> Ptr Word8 -> IO ()
    loop n p
        | n <= 15   = do
            poke p (BSU.unsafeIndex hexDigits (fromIntegral n .&. 0x0F))
        | otherwise = do
            let (q,r) = n `quotRem` 16
            poke p (BSU.unsafeIndex hexDigits (fromIntegral r .&. 0x0F))
            loop q (p `plusPtr` negate 1)


-- Inspired by, <http://forums.xkcd.com/viewtopic.php?f=11&t=16666&p=553936>
-- | Convert a bitvector into a lower-case ASCII hexadecimal string.
-- This is helpful for visualizing raw binary data, rather than for
-- parsing as such.
asHexadecimal :: ByteString -> ByteString
asHexadecimal = start
    where
    start buf =
        BSI.unsafeCreate (2 * BS.length buf) $ \p0 -> do
            _ <- foldIO step p0 buf
            return () -- needed for type checking
    
    step :: Ptr Word8 -> Word8 -> IO (Ptr Word8)
    step p w
        | p `seq` w `seq` False = undefined -- for strictness analysis
        | otherwise = do
            let ix = fromIntegral w
            poke   p     (BSU.unsafeIndex hexDigits ((ix .&. 0xF0) `shiftR` 4))
            poke   (p `plusPtr` 1) (BSU.unsafeIndex hexDigits  (ix .&. 0x0F))
            return (p `plusPtr` 2)

-- TODO: benchmark against the magichash hack used in Warp.
-- | The lower-case ASCII hexadecimal digits, in numerical order
-- for use as a lookup table.
hexDigits :: ByteString
{-# NOINLINE hexDigits #-}
hexDigits = BS8.pack "0123456789abcdef"

-- | We can only do this for MonadIO not just any Monad, but that's
-- good enough for what we need...
foldIO :: (a -> Word8 -> IO a) -> a -> ByteString -> IO a
{-# INLINE foldIO #-}
foldIO f z0 (BSI.PS fp off len) =
    FFI.withForeignPtr fp $ \p0 -> do
        let q = p0 `plusPtr` (off+len)
        let go z p
                | z `seq` p `seq` False = undefined -- for strictness analysis
                | p == q    = return z
                | otherwise = do
                    w  <- peek p
                    z' <- f z w
                    go z' (p `plusPtr` 1)
        go z0 (p0 `plusPtr` off)


----------------------------------------------------------------
----- Octal

-- | Read a positive integral value in ASCII octal format. Returns
-- @Nothing@ if there is no integer at the beginning of the string,
-- otherwise returns @Just@ the integer read and the remainder of
-- the string.
--
-- This function does not recognize the various octal sigils like
-- \"0o\", but because there are different variants, those are best
-- handled by helper functions which then use this one for the
-- numerical parsing.
readOctal :: (Integral a) => ByteString -> Maybe (a, ByteString)
{-# SPECIALIZE readOctal ::
    ByteString -> Maybe (Int,     ByteString),
    ByteString -> Maybe (Int8,    ByteString),
    ByteString -> Maybe (Int16,   ByteString),
    ByteString -> Maybe (Int32,   ByteString),
    ByteString -> Maybe (Int64,   ByteString),
    ByteString -> Maybe (Integer, ByteString),
    ByteString -> Maybe (Word,    ByteString),
    ByteString -> Maybe (Word8,   ByteString),
    ByteString -> Maybe (Word16,  ByteString),
    ByteString -> Maybe (Word32,  ByteString),
    ByteString -> Maybe (Word64,  ByteString) #-}
readOctal = start
    where
    start xs
        | BS.null xs = Nothing
        | otherwise  =
            case BSU.unsafeHead xs of
            w | 0x30 <= w && w <= 0x37 ->
                    Just $ loop (fromIntegral (w - 0x30)) (BSU.unsafeTail xs)
              | otherwise -> Nothing
    
    loop n xs
        | n `seq` xs `seq` False = undefined -- for strictness analysis
        | BS.null xs = (n, BS.empty)         -- not @xs@, to help GC
        | otherwise  =
            case BSU.unsafeHead xs of
            w | 0x30 <= w && w <= 0x37 ->
                    loop (n * 8 + fromIntegral (w - 0x30)) (BSU.unsafeTail xs)
              | otherwise -> (n,xs)


-- | Convert a positive integer into an ASCII octal string. Returns
-- @Nothing@ on negative inputs.
packOctal :: (Integral a) => a -> Maybe ByteString
{-# SPECIALIZE packOctal ::
    Int     -> Maybe ByteString,
    Int8    -> Maybe ByteString,
    Int16   -> Maybe ByteString,
    Int32   -> Maybe ByteString,
    Int64   -> Maybe ByteString,
    Integer -> Maybe ByteString,
    Word    -> Maybe ByteString,
    Word8   -> Maybe ByteString,
    Word16  -> Maybe ByteString,
    Word32  -> Maybe ByteString,
    Word64  -> Maybe ByteString #-}
packOctal = start
    where
    start n0
        | n0 < 0    = Nothing
        | otherwise = Just $
            let size = twoPowerNumDigits 3 (toInteger n0) -- for Bits
            in  BSI.unsafeCreate size $ \p0 ->
                    loop n0 (p0 `plusPtr` (size - 1))
    
    loop :: (Integral a) => a -> Ptr Word8 -> IO ()
    loop n p
        | n <= 7    = do
            poke p (0x30 + fromIntegral n)
        | otherwise = do
            let (q,r) = n `quotRem` 8
            poke p (0x30 + fromIntegral r)
            loop q (p `plusPtr` negate 1)


{-
-- @ceilEightThirds x == ceiling (fromIntegral x * 8 / 3)@
ceilEightThirds :: Nat -> Nat
ceilEightThirds (Nat# x)
    | 0 == r    = Nat# q
    | otherwise = Nat# (q+1)
    where
    (q,r) = (x * 8) `quotRem` 3

asOctal :: ByteString -> ByteString
asOctal buf =
    BSI.unsafeCreate (ceilEightThirds $ BS.length buf) $ \p0 -> do
        let (BSI.PS fq off len) = buf
        FFI.withForeignPtr fq $ \q0 -> do
            let qF = q0 `plusPtr` (off + len - rem len 3)
            let loop p q
                    | q == qF   = ...{- Handle the last one or two Word8 -}
                    | otherwise = do
                        ...{- Take three Word8 and write 8 chars  at a time -}
                        -- Cf. the @word24@ package
                        loop (p `plusPtr` 8) (q `plusPtr` 3)
            
            loop p0 (q0 `plusPtr` off)

            {- N.B., @BSU.unsafeIndex octDigits == (0x30 +)@ -}
-}


----------------------------------------------------------------
----- Integral logarithms

-- TODO: cf. integer-gmp:GHC.Integer.Logarithms made available in version 0.3.0.0 (ships with GHC 7.2.1).
-- <http://haskell.org/ghc/docs/7.2.1/html/libraries/integer-gmp-0.3.0.0/GHC-Integer-Logarithms.html>


-- This implementation is derived from
-- <http://www.haskell.org/pipermail/haskell-cafe/2009-August/065854.html>
-- modified to use 'quot' instead of 'div', to ensure strictness,
-- and using more guard notation (but this last one's compiled
-- away). See @./test/bench/BenchNumDigits.hs@ for other implementation
-- choices.
--
-- | @numDigits b n@ computes the number of base-@b@ digits required
-- to represent the number @n@. N.B., this implementation is unsafe
-- and will throw errors if the base is @(<= 1)@, or if the number
-- is negative. If the base happens to be a power of 2, then see
-- 'twoPowerNumDigits' for a more efficient implementation.
--
-- We must be careful about the input types here. When using small
-- unsigned types or very large values, the repeated squaring can
-- overflow causing the function to loop. (E.g., the fourth squaring
-- of 10 overflows 32-bits (==1874919424) which is greater than the
-- third squaring. For 64-bit, the 5th squaring overflows, but it's
-- negative so will be caught.) Forcing the type to Integer ensures
-- correct behavior, but makes it substantially slower.

numDigits :: Integer -> Integer -> Int
{-# INLINE numDigits #-}
numDigits b0 n0
    | b0 <= 1   = error _numDigits_nonpositiveBase
    | n0 <  0   = error _numDigits_negativeNumber
    | otherwise = 1 + fst (ilog b0 n0)
    where
    ilog b n
        | n < b     = (0, n)
        | r < b     = ((,) $! 2*e) r
        | otherwise = ((,) $! 2*e+1) $! (r `quot` b)
        where
        (e, r) = ilog (b*b) n

_numDigits_nonpositiveBase :: String
{-# NOINLINE _numDigits_nonpositiveBase #-}
_numDigits_nonpositiveBase = "numDigits: base must be greater than one"

_numDigits_negativeNumber  :: String
{-# NOINLINE _numDigits_negativeNumber #-}
_numDigits_negativeNumber  = "numDigits: number must be non-negative"


-- | Compute the number of base-@2^p@ digits required to represent a
-- number @n@. N.B., this implementation is unsafe and will throw
-- errors if the base power is non-positive, or if the number is
-- negative. For bases which are not a power of 2, see 'numDigits'
-- for a more general implementation.
twoPowerNumDigits :: (Integral a, Bits a) => Int -> a -> Int
{-# INLINE twoPowerNumDigits #-}
twoPowerNumDigits p n0
    | p  <= 0   = error _twoPowerNumDigits_nonpositiveBase
    | n0 <  0   = error _twoPowerNumDigits_negativeNumber
    | n0 == 0   = 1
    | otherwise = go 0 n0
    where
    go d n
        | d `seq` n `seq` False = undefined
        | n > 0     = go (d+1) (n `shiftR` p)
        | otherwise = d

_twoPowerNumDigits_nonpositiveBase :: String
{-# NOINLINE _twoPowerNumDigits_nonpositiveBase #-}
_twoPowerNumDigits_nonpositiveBase =
    "twoPowerNumDigits: base must be positive"

_twoPowerNumDigits_negativeNumber :: String
{-# NOINLINE _twoPowerNumDigits_negativeNumber #-}
_twoPowerNumDigits_negativeNumber =
    "twoPowerNumDigits: number must be non-negative"

----------------------------------------------------------------
----------------------------------------------------------- fin.
