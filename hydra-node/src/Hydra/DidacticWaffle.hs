module Hydra.DidacticWaffle where

import Hydra.Prelude

data UTxOSet = UTxOSet
  deriving (Eq, Show)

data State
  = Initial {utxos :: UTxOSet}
  | Closed
  | Final
  deriving (Eq, Show)
