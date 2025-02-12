-- | Simplified interface to phase-2 validation of transaction, eg. evaluation of Plutus scripts.
--
-- The `evaluateTx` function simplifies the call to underlying Plutus providing execution report
-- using pre-canned `PParams`. This should only be used for /testing/ or /benchmarking/ purpose
-- as the real evaluation parameters are set when the Hydra node starts.
--
-- __NOTE__: The reason this module is here instead of part of `test/` directory is to be used
-- in @tx-cost@ executable.
module Hydra.Ledger.Cardano.Evaluate where

import Hydra.Prelude hiding (label)

import Cardano.Ledger.Alonzo.Language (Language (PlutusV1, PlutusV2))
import Cardano.Ledger.Alonzo.PParams (PParams, PParams' (..))
import Cardano.Ledger.Alonzo.Scripts (CostModel (..), ExUnits (..), Prices (..))
import Cardano.Ledger.Alonzo.Tools (
  BasicFailure,
  ScriptFailure,
  evaluateTransactionExecutionUnits,
 )
import Cardano.Ledger.Alonzo.TxInfo (slotToPOSIXTime)
import Cardano.Ledger.Alonzo.TxWitness (RdmrPtr)
import Cardano.Ledger.BaseTypes (ProtVer (..), boundRational)
import Cardano.Slotting.EpochInfo (EpochInfo, fixedEpochInfo)
import Cardano.Slotting.Slot (EpochSize (EpochSize), SlotNo (SlotNo))
import Cardano.Slotting.Time (RelativeTime (RelativeTime), SlotLength (getSlotLength), SystemStart (SystemStart), mkSlotLength, toRelativeTime)
import Data.Array (Array, array)
import Data.Bits (shift)
import Data.Default (def)
import qualified Data.Map as Map
import Data.Maybe (fromJust)
import Data.Ratio ((%))
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Hydra.Cardano.Api (ExecutionUnits, StandardCrypto, Tx, UTxO, fromLedgerExUnits, toLedgerExUnits, toLedgerTx, toLedgerUTxO)
import Hydra.Chain.Direct.Util (Era)
import qualified Plutus.V1.Ledger.Api as PV1
import qualified Plutus.V1.Ledger.Api as Plutus
import qualified Plutus.V2.Ledger.Api as PV2
import Test.QuickCheck (choose)

type RedeemerReport =
  (Map RdmrPtr (Either (ScriptFailure StandardCrypto) ExUnits))

evaluateTx ::
  Tx ->
  UTxO ->
  Either (BasicFailure StandardCrypto) RedeemerReport
evaluateTx = evaluateTx' (fromLedgerExUnits $ _maxTxExUnits pparams)

evaluateTx' ::
  -- | Max tx execution units.
  ExecutionUnits ->
  Tx ->
  UTxO ->
  Either (BasicFailure StandardCrypto) RedeemerReport
evaluateTx' maxTxExUnits tx utxo =
  runIdentity $
    evaluateTransactionExecutionUnits
      pparams{_maxTxExUnits = toLedgerExUnits maxTxExUnits}
      (toLedgerTx tx)
      (toLedgerUTxO utxo)
      epochInfo
      systemStart
      costModels

-- | Cost models used in 'evaluateTx'. See also 'pparams' and 'defaultCostModel'
costModels :: Array Language CostModel
costModels =
  array
    (PlutusV1, PlutusV1)
    [(PlutusV1, fromJust $ defaultCostModel PlutusV1)]

-- | Current mainchain cost parameters.
pparams :: PParams Era
pparams =
  def
    { _costmdls = Map.singleton PlutusV1 $ fromJust $ defaultCostModel PlutusV1
    , _maxValSize = 1000000000
    , _maxTxExUnits = ExUnits 14_000_000 10_000_000_000
    , _maxBlockExUnits = ExUnits 56_000_000 40_000_000_000
    , _protocolVersion = ProtVer 6 0
    , _maxTxSize = 1 `shift` 14 -- 16kB
    , _prices =
        Prices
          { prMem = fromJust $ boundRational $ 721 % 10000000
          , prSteps = fromJust $ boundRational $ 577 % 10000
          }
    }

-- | Default cost model used in 'pparams'.
defaultCostModel :: Language -> Maybe CostModel
defaultCostModel = \case
  PlutusV1 -> CostModel <$> PV1.defaultCostModelParams
  PlutusV2 -> CostModel <$> PV2.defaultCostModelParams

epochInfo :: Monad m => EpochInfo m
epochInfo = fixedEpochInfo (EpochSize 100) slotLength

slotLength :: SlotLength
slotLength = mkSlotLength 1

systemStart :: SystemStart
systemStart = SystemStart $ posixSecondsToUTCTime 0

genPointInTime :: Gen (SlotNo, Plutus.POSIXTime)
genPointInTime = do
  slot <- arbitrary
  pure (slot, slotNoToPOSIXTime slot)

genPointInTimeBefore :: Plutus.POSIXTime -> Gen (SlotNo, Plutus.POSIXTime)
genPointInTimeBefore deadline = do
  let SlotNo slotDeadline = slotNoFromPOSIXTime deadline
  slot <- SlotNo <$> choose (0, slotDeadline)
  pure (slot, slotNoToPOSIXTime slot)

genPointInTimeAfter :: Plutus.POSIXTime -> Gen (SlotNo, Plutus.POSIXTime)
genPointInTimeAfter deadline = do
  let SlotNo slotDeadline = slotNoFromPOSIXTime deadline
  slot <- SlotNo <$> choose (slotDeadline, maxBound)
  pure (slot, slotNoToPOSIXTime slot)

-- | Using hard-coded systemStart and slotLength, do not use in production!
slotNoFromPOSIXTime :: Plutus.POSIXTime -> SlotNo
slotNoFromPOSIXTime posixTime =
  SlotNo $ truncate (relativeTime / getSlotLength slotLength)
 where
  (RelativeTime relativeTime) =
    toRelativeTime systemStart utcTime

  utcTime =
    posixSecondsToUTCTime $
      realToFrac $
        (`div` 1000) $
          Plutus.getPOSIXTime posixTime

-- | Using hard-coded epochInfo and systemStart, do not use in production!
slotNoToPOSIXTime :: SlotNo -> Plutus.POSIXTime
slotNoToPOSIXTime =
  runIdentity
    . slotToPOSIXTime
      pparams
      epochInfo
      systemStart
