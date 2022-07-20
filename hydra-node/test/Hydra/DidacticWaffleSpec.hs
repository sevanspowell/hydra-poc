module Hydra.DidacticWaffleSpec where

import Hydra.Prelude
import Test.Hydra.Prelude

import Hydra.DidacticWaffle (State (State))
import Test.QuickCheck ((===))

spec :: Spec
spec =
  it "can transition through full lifecycle" $
    (initialize Params
     & commit
     & collect
     & close
     & fanout) == Final
