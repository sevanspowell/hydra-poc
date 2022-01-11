{-# OPTIONS_GHC -fno-specialize #-}

module Plutus.Codec.CBOR.Encoding (
  Encoding,
  encodingToBuiltinByteString,
  encodeInteger,
  encodeByteString,
  encodeNull,
  encodeListLen,
  encodeBeginList,
  encodeList,
  encodeListIndef,
  encodeMapLen,
  encodeBeginMap,
  encodeMap,
  encodeMapIndef,
  encodeBreak,
  encodeMaybe,
) where

import PlutusTx.Prelude

import PlutusTx.AssocMap (Map)
import qualified PlutusTx.AssocMap as Map
import PlutusTx.Builtins (subtractInteger)

-- * Encoding

newtype Encoding = Encoding (BuiltinByteString -> BuiltinByteString)

instance Semigroup Encoding where
  (Encoding a) <> (Encoding b) = Encoding (a . b)

instance Monoid Encoding where
  mempty = Encoding id

encodingToBuiltinByteString :: Encoding -> BuiltinByteString
encodingToBuiltinByteString (Encoding runEncoder) =
  runEncoder emptyByteString
{-# INLINEABLE encodingToBuiltinByteString #-}

-- * Basic types

encodeInteger :: Integer -> Encoding
encodeInteger n
  | n < 0 =
    Encoding (encodeUnsigned 1 (subtractInteger 0 n - 1))
  | otherwise =
    Encoding (encodeUnsigned 0 n)
{-# INLINEABLE encodeInteger #-}

encodeByteString :: BuiltinByteString -> Encoding
encodeByteString bytes =
  Encoding (encodeUnsigned 2 (lengthOfByteString bytes) . appendByteString bytes)
{-# INLINEABLE encodeByteString #-}

encodeNull :: Encoding
encodeNull =
  Encoding (consByteString 246)
{-# INLINEABLE encodeNull #-}

-- * Data-Structure

-- | Declare a list of fixed size. Then, provide each element of the list
-- separately via appending them ('Encoding' is a 'Semigroup').
--
-- This is useful to construct non-uniform arrays where elements may have
-- different types. For uniform list, see 'encodeList'.
encodeListLen :: Integer -> Encoding
encodeListLen = Encoding . encodeUnsigned 4
{-# INLINEABLE encodeListLen #-}

encodeList :: (a -> Encoding) -> [a] -> Encoding
encodeList encodeElem =
  step 0 mempty
 where
  step !n !bs = \case
    [] -> encodeListLen n <> bs
    (e : q) -> step (n+1) (bs <> encodeElem e) q
{-# INLINEABLE encodeList #-}

encodeListIndef :: (a -> Encoding) -> [a] -> Encoding
encodeListIndef encodeElem es =
  encodeBeginList <> step es
 where
  step = \case
    [] -> encodeBreak
    (e : q) -> encodeElem e <> step q
{-# INLINEABLE encodeListIndef #-}

encodeBeginList :: Encoding
encodeBeginList = Encoding (withMajorType 4 31)
{-# INLINEABLE encodeBeginList #-}

encodeBreak :: Encoding
encodeBreak = Encoding (consByteString 0xFF)
{-# INLINEABLE encodeBreak #-}

encodeMaybe :: (a -> Encoding) -> Maybe a -> Encoding
encodeMaybe encode = \case
  Nothing -> Encoding id
  Just a -> encode a
{-# INLINEABLE encodeMaybe #-}

-- | Declare a map of fixed size. Then, provide each key/value pair of the map
-- separately via appending them ('Encoding' is a 'Semigroup').
--
-- This is useful to construct non-uniform maps where keys and values may have
-- different types. For uniform maps, see 'encodeMap'.
encodeMapLen :: Integer -> Encoding
encodeMapLen = Encoding . encodeUnsigned 5
{-# INLINEABLE encodeMapLen #-}

encodeMap :: (k -> Encoding) -> (v -> Encoding) -> Map k v -> Encoding
encodeMap encodeKey encodeValue =
  step 0 mempty . Map.toList
 where
  step n bs = \case
    [] -> encodeMapLen n <> bs
    ((k,v) : q) -> step (n+1) (bs <> encodeKey k <> encodeValue v) q
{-# INLINEABLE encodeMap #-}

encodeMapIndef :: (k -> Encoding) -> (v -> Encoding) -> Map k v -> Encoding
encodeMapIndef encodeKey encodeValue m =
  encodeBeginMap <> step (Map.toList m)
 where
  step = \case
    [] -> encodeBreak
    ((k,v) : q) -> encodeKey k <> encodeValue v <> step q
{-# INLINEABLE encodeMapIndef #-}

encodeBeginMap :: Encoding
encodeBeginMap = Encoding (withMajorType 5 31)
{-# INLINEABLE encodeBeginMap #-}

-- * Internal

withMajorType :: Integer -> Integer -> BuiltinByteString -> BuiltinByteString
withMajorType major n =
  consByteString (32 * major + n)
{-# INLINEABLE withMajorType #-}

encodeUnsigned :: Integer -> Integer -> BuiltinByteString -> BuiltinByteString
encodeUnsigned major n next
  | n < 24 =
    withMajorType major n next
  | n < 256 =
    withMajorType major 24 (encodeUnsigned8 n next)
  | n < 65536 =
    withMajorType major 25 (encodeUnsigned16 n next)
  | n < 4294967296 =
    withMajorType major 26 (encodeUnsigned32 n next)
  | otherwise =
    withMajorType major 27 (encodeUnsigned64 n next)
{-# INLINEABLE encodeUnsigned #-}

encodeUnsigned8 :: Integer -> BuiltinByteString -> BuiltinByteString
encodeUnsigned8 = consByteString
{-# INLINEABLE encodeUnsigned8 #-}

encodeUnsigned16 :: Integer -> BuiltinByteString -> BuiltinByteString
encodeUnsigned16 n =
  encodeUnsigned8 (quotient n 256) . encodeUnsigned8 (remainder n 256)
{-# INLINEABLE encodeUnsigned16 #-}

encodeUnsigned32 :: Integer -> BuiltinByteString -> BuiltinByteString
encodeUnsigned32 n =
  encodeUnsigned16 (quotient n 65536) . encodeUnsigned16 (remainder n 65536)
{-# INLINEABLE encodeUnsigned32 #-}

encodeUnsigned64 :: Integer -> BuiltinByteString -> BuiltinByteString
encodeUnsigned64 n =
  encodeUnsigned32 (quotient n 4294967296) . encodeUnsigned32 (remainder n 4294967296)
{-# INLINEABLE encodeUnsigned64 #-}
