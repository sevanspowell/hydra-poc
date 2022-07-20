module Hydra.DidacticWaffle where

import Hydra.Prelude

data UTxOSet = UTxOSet
  deriving (Eq, Show)

-- {utxos :: UTxOSet}

data State
  = Initial
  | Open
  | Closed
  | Final
  deriving (Eq, Show)

-- () -> Initial
-- Final -> ()

data Params = Params

-- data Machine = Machine { state :: State }

initialize :: Params -> State
initialize = undefined

commit :: UTxO -> State -> State
commit = undefined

-- Maybe something to collect here?
collect :: State -> State
collect = undefined

close :: State -> State
close = undefined

fanout :: State -> State
fanout = undefined

abort :: State -> State
abort = undefined
