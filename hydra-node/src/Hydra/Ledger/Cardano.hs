{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-missing-methods #-}
{-# OPTIONS_GHC -Wno-orphans #-}

module Hydra.Ledger.Cardano where

import Hydra.Prelude hiding (id)

import Cardano.Binary (decodeFull', serialize')
import Cardano.Ledger.Crypto (Crypto, StandardCrypto)
import Cardano.Ledger.Mary (MaryEra)
import qualified Cardano.Ledger.Mary.Value as Cardano
import Data.Aeson (Value (String), object, withText, (.=))
import Data.ByteString.Base16 (decodeBase16, encodeBase16)
import qualified Data.Set as Set
import Hydra.Ledger (Tx (..))
import qualified Shelley.Spec.Ledger.API as Cardano
import Text.Read (readPrec)

type CardanoEra = MaryEra StandardCrypto

data CardanoTx = CardanoTx
  { id :: Cardano.TxId StandardCrypto
  , body :: CardanoTxBody
  , witnesses :: CardanoTxWitnesses
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- TODO(SN): ditch these and use To/FromJSON instead
instance Read CardanoTx where
  readPrec = error "Read: CardanoTx"

-- TODO(SN): ditch these and use To/FromJSON instead
instance Read (Cardano.UTxO era) where
  readPrec = error "Read: Cardano.UTxO"

-- TODO(SN): ditch these and use To/FromJSON instead
instance Read (Cardano.TxId era) where
  readPrec = error "Read: Cardano.TxId"

txIdToText :: forall crypto. Crypto crypto => Cardano.TxId crypto -> Text
txIdToText = encodeBase16 . serialize'

txIdFromText :: (MonadFail m, Crypto crypto) => Text -> m (Cardano.TxId crypto)
txIdFromText t =
  case decodeBase16 (encodeUtf8 t) of
    Left e -> fail $ show e
    Right bytes -> case decodeFull' bytes of
      Left e -> fail $ show e
      Right a -> pure a

instance Crypto crypto => ToJSON (Cardano.TxId crypto) where
  toJSON = String . txIdToText @crypto

instance Crypto crypto => FromJSON (Cardano.TxId crypto) where
  parseJSON = withText "base16 encoded TxId" txIdFromText

instance FromJSON CardanoTxBody where
  parseJSON = error "TODO: FromJSON CardanoTxBody"

instance ToJSON CardanoTxBody where
  toJSON (Cardano.TxBody inputs outputs _certs _wdrls _txfee _vldt _update _mdHash) =
    object
      [ "inputs" .= Set.map inputToJson inputs
      , "outputs" .= fmap outputToJson outputs
      ]

inputToJson :: Cardano.TxIn StandardCrypto -> Value
inputToJson (Cardano.TxIn id ix) =
  toJSON (txIdToText id <> "#" <> show ix)

outputToJson :: Cardano.TxOut CardanoEra -> Value
outputToJson (Cardano.TxOut addr value) =
  object
    -- TODO: Use ledger's instance, which is a base16-encoded
    -- serialized address. We might want to use bech32
    -- serialization in the end.
    [ "address" .= addr
    , "value" .= valueToJson value
    ]

valueToJson :: Cardano.Value StandardCrypto -> Value
valueToJson =
  error "TODO: valueToJson"

instance Semigroup (Cardano.UTxO CardanoEra) where
  Cardano.UTxO u1 <> Cardano.UTxO u2 = Cardano.UTxO (u1 <> u2)

instance Monoid (Cardano.UTxO CardanoEra) where
  mempty = Cardano.UTxO mempty

instance ToJSON (Cardano.UTxO era) where
  toJSON = error "toJSON: Cardano.UTxO"

instance FromJSON (Cardano.UTxO era) where
  parseJSON = error "parseJSON: Cardano.UTxO"

instance ToJSON CardanoTxWitnesses where
  toJSON = error "toJSON: CardanoTxWitnesses"

instance FromJSON CardanoTxWitnesses where
  parseJSON = error "parseJSON: CardanoTxWitnesses"

type CardanoTxBody = Cardano.TxBody CardanoEra

type CardanoTxWitnesses = Cardano.WitnessSet CardanoEra

instance Tx CardanoTx where
  type Utxo CardanoTx = Cardano.UTxO CardanoEra
  type TxId CardanoTx = Cardano.TxId StandardCrypto

  txId = id