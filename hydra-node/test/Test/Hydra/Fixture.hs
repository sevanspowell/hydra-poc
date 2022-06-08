-- | Test and example values used across hydra-node tests.
module Test.Hydra.Fixture where

import Hydra.Cardano.Api (SigningKey)
import Hydra.Crypto (HydraKey, generateSigningKey)
import Hydra.Party (Party, deriveParty)

aliceSk, bobSk, carolSk :: SigningKey HydraKey
aliceSk = generateSigningKey "alice"
bobSk = generateSigningKey "bob"
carolSk = generateSigningKey "carol"

alice, bob, carol :: Party
alice = deriveParty aliceSk
bob = deriveParty bobSk
carol = deriveParty carolSk
