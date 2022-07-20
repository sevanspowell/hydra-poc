module Hydra.DidacticWaffleSpec where

import Hydra.Prelude
import Test.Hydra.Prelude

import Hydra.DidacticWaffle (State (State))
import Test.QuickCheck ((===))

spec :: Spec
spec =
  it "exists" $ State === State
