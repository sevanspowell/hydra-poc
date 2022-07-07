{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeApplications #-}

module CardanoNode where

import Hydra.Prelude

import Control.Tracer (Tracer, traceWith)
import Data.Aeson ((.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as Aeson.KeyMap
import Data.Time.Clock.POSIX (posixSecondsToUTCTime, utcTimeToPOSIXSeconds)
import Hydra.Cardano.Api (AsType (AsPaymentKey), PaymentKey, SigningKey, VerificationKey, generateSigningKey, getVerificationKey)
import Hydra.Cluster.Fixture (KnownNetwork (Testnet, VasilTestnet))
import Hydra.Cluster.Util (readConfigFile)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.Exit (ExitCode (..))
import System.FilePath ((<.>), (</>))
import System.Posix (ownerReadMode, setFileMode)
import System.Process (
  CreateProcess (..),
  StdStream (UseHandle),
  proc,
  readProcess,
  withCreateProcess,
 )
import Test.Hydra.Prelude
import Test.Network.Ports (randomUnusedTCPPort)

type Port = Int

newtype NodeId = NodeId Int
  deriving newtype (Eq, Show, Num, ToJSON, FromJSON)

data RunningNode = RunningNode NodeId FilePath

-- | Configuration parameters for a single node of the cluster
data CardanoNodeConfig = CardanoNodeConfig
  { -- | An identifier for the node
    nodeId :: NodeId
  , -- | Parent state directory in which create a state directory for the cluster
    stateDirectory :: FilePath
  , -- | Blockchain start time
    systemStart :: UTCTime
  , -- | A list of port
    ports :: PortsConfig
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newNodeConfig :: FilePath -> IO CardanoNodeConfig
newNodeConfig stateDirectory = do
  nodePort <- randomUnusedTCPPort
  systemStart <- initSystemStart
  pure $
    CardanoNodeConfig
      { nodeId = 1
      , stateDirectory
      , systemStart
      , ports = PortsConfig nodePort []
      }

-- | Arguments given to the 'cardano-node' command-line to run a node.
data CardanoNodeArgs = CardanoNodeArgs
  { nodeSocket :: FilePath
  , nodeConfigFile :: FilePath
  , nodeByronGenesisFile :: FilePath
  , nodeShelleyGenesisFile :: FilePath
  , nodeAlonzoGenesisFile :: FilePath
  , nodeTopologyFile :: FilePath
  , nodeDatabaseDir :: FilePath
  , nodeDlgCertFile :: Maybe FilePath
  , nodeSignKeyFile :: Maybe FilePath
  , nodeOpCertFile :: Maybe FilePath
  , nodeKesKeyFile :: Maybe FilePath
  , nodeVrfKeyFile :: Maybe FilePath
  , nodePort :: Maybe Port
  }

defaultCardanoNodeArgs :: CardanoNodeArgs
defaultCardanoNodeArgs =
  CardanoNodeArgs
    { nodeSocket = "node.socket"
    , nodeConfigFile = "configuration.json"
    , nodeByronGenesisFile = "genesis-byron.json"
    , nodeShelleyGenesisFile = "genesis-shelley.json"
    , nodeAlonzoGenesisFile = "genesis-alonzo.json"
    , nodeTopologyFile = "topology.json"
    , nodeDatabaseDir = "db"
    , nodeDlgCertFile = Nothing
    , nodeSignKeyFile = Nothing
    , nodeOpCertFile = Nothing
    , nodeKesKeyFile = Nothing
    , nodeVrfKeyFile = Nothing
    , nodePort = Nothing
    }

-- | Configuration of ports from the perspective of a peer in the context of a
-- fully sockected topology.
data PortsConfig = PortsConfig
  { -- | Our node TCP port.
    ours :: Port
  , -- | Other peers TCP ports.
    peers :: [Port]
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (ToJSON, FromJSON)

getCardanoNodeVersion :: IO String
getCardanoNodeVersion =
  readProcess "cardano-node" ["--version"] ""

-- | Start a cardano-node in BFT mode using the config from config/ and
-- credentials from config/credentials/ using given 'nodeId'. Only the 'Faucet'
-- actor will receive "initialFunds". Use 'seedFromFaucet' to distribute funds
-- other wallets.
--
-- FIXME: This is actually not a BFT node and it also only supports nodeId == 1.
-- We should rename this function and also think about removing the `nodeId`
-- from `CardanoNodeConfig` as it is a lie.
withBFTNode ::
  Tracer IO NodeLog ->
  CardanoNodeConfig ->
  (RunningNode -> IO ()) ->
  IO ()
withBFTNode tracer cfg action = do
  createDirectoryIfMissing True (stateDirectory cfg </> dirname)

  [dlgCert, signKey, vrfKey, kesKey, opCert] <-
    forM
      [ dlgCertFilename
      , signKeyFilename
      , vrfKeyFilename
      , kesKeyFilename
      , opCertFilename
      ]
      (copyCredential (stateDirectory cfg))

  let args =
        defaultCardanoNodeArgs
          { nodeDlgCertFile = Just dlgCert
          , nodeSignKeyFile = Just signKey
          , nodeVrfKeyFile = Just vrfKey
          , nodeKesKeyFile = Just kesKey
          , nodeOpCertFile = Just opCert
          , nodePort = Just (ours (ports cfg))
          }

  readConfigFile "cardano-node.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeConfigFile args)

  readConfigFile "genesis-byron.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeByronGenesisFile args)

  readConfigFile "genesis-shelley.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeShelleyGenesisFile args)

  readConfigFile "genesis-alonzo.json"
    >>= writeFileBS
      (stateDirectory cfg </> nodeAlonzoGenesisFile args)

  withCardanoNode tracer cfg args $ \rn@(RunningNode _ socket) -> do
    traceWith tracer $ MsgNodeStarting cfg
    waitForSocket rn
    traceWith tracer $ MsgSocketIsReady socket
    action rn
 where
  dirname =
    "stake-pool-" <> show (nodeId cfg)

  dlgCertFilename =
    dirname </> "byron-delegation.cert"
  signKeyFilename =
    dirname </> "byron-delegate.key"
  vrfKeyFilename =
    dirname </> "vrf.skey"
  kesKeyFilename =
    dirname </> "kes.skey"
  opCertFilename =
    dirname </> "opcert.cert"

  copyCredential parentDir file = do
    bs <- readConfigFile ("credentials" </> file)
    let destination = parentDir </> file
    unlessM (doesFileExist destination) $
      writeFileBS destination bs
    setFileMode destination ownerReadMode
    pure destination

-- | Run a cardano-node as normal network participant on a known network.
withCardanoNodeOnKnownNetwork ::
  Tracer IO NodeLog ->
  FilePath ->
  KnownNetwork ->
  (RunningNode -> IO ()) ->
  IO ()
withCardanoNodeOnKnownNetwork tracer workDir knownNetwork action = do
  config <- newNodeConfig workDir
  copyKnownNetworkFiles
  withCardanoNode tracer config args $ \rn@(RunningNode _ socket) -> do
    traceWith tracer $ MsgNodeStarting config
    waitForSocket rn
    traceWith tracer $ MsgSocketIsReady socket
    action rn
 where
  args =
    defaultCardanoNodeArgs
      { nodeConfigFile = "config.json"
      , nodeTopologyFile = "topology.json"
      , nodeByronGenesisFile = "genesis/byron.json"
      , nodeShelleyGenesisFile = "genesis/shelley.json"
      , nodeAlonzoGenesisFile = "genesis/alonzo.json"
      }

  copyKnownNetworkFiles = do
    createDirectoryIfMissing True $ workDir </> "genesis"
    readConfigFile (knownNetworkPath </> "cardano-node" </> "config.json")
      >>= writeFileBS (workDir </> "config.json")
    readConfigFile (knownNetworkPath </> "cardano-node" </> "topology.json")
      >>= writeFileBS (workDir </> "topology.json")
    readConfigFile (knownNetworkPath </> "genesis" </> "byron.json")
      >>= writeFileBS (workDir </> "genesis" </> "byron.json")
    readConfigFile (knownNetworkPath </> "genesis" </> "shelley.json")
      >>= writeFileBS (workDir </> "genesis" </> "shelley.json")
    readConfigFile (knownNetworkPath </> "genesis" </> "alonzo.json")
      >>= writeFileBS (workDir </> "genesis" </> "alonzo.json")

  -- Folder name in config/cardano-configurations/network
  knownNetworkName = case knownNetwork of
    Testnet -> "testnet"
    VasilTestnet -> "vasil-dev"

  knownNetworkPath =
    "cardano-configurations" </> "network" </> knownNetworkName

withCardanoNode ::
  Tracer IO NodeLog ->
  CardanoNodeConfig ->
  CardanoNodeArgs ->
  (RunningNode -> IO ()) ->
  IO ()
withCardanoNode tr cfg@CardanoNodeConfig{stateDirectory, nodeId} args action = do
  generateEnvironment
  let process = cardanoNodeProcess (Just stateDirectory) args
      logFile = stateDirectory </> show nodeId <.> "log"
  traceWith tr $ MsgNodeCmdSpec (show $ cmdspec process)
  withFile' logFile $ \out ->
    withCreateProcess process{std_out = UseHandle out, std_err = UseHandle out} $ \_stdin _stdout _stderr processHandle ->
      race_
        (checkProcessHasNotDied ("cardano-node-" <> show nodeId) processHandle)
        (action (RunningNode nodeId (stateDirectory </> nodeSocket args)))
        `finally` cleanupSocketFile
 where
  generateEnvironment = do
    refreshSystemStart cfg args
    let topology = mkTopology $ peers $ ports cfg
    Aeson.encodeFile (stateDirectory </> nodeTopologyFile args) topology

  cleanupSocketFile =
    whenM (doesFileExist socketFile) $
      removeFile socketFile

  socketFile = stateDirectory </> nodeSocket args

-- | Wait for the node socket file to become available.
waitForSocket :: RunningNode -> IO ()
waitForSocket node@(RunningNode _ socket) = do
  unlessM (doesFileExist socket) $ do
    threadDelay 0.1
    waitForSocket node

-- | Generate command-line arguments for launching @cardano-node@.
cardanoNodeProcess :: Maybe FilePath -> CardanoNodeArgs -> CreateProcess
cardanoNodeProcess cwd args = (proc "cardano-node" strArgs){cwd}
 where
  strArgs =
    "run" :
    mconcat
      [ ["--config", nodeConfigFile args]
      , ["--topology", nodeTopologyFile args]
      , ["--database-path", nodeDatabaseDir args]
      , ["--socket-path", nodeSocket args]
      , opt "--port" (show <$> nodePort args)
      , opt "--byron-signing-key" (nodeSignKeyFile args)
      , opt "--byron-delegation-certificate" (nodeDlgCertFile args)
      , opt "--shelley-operational-certificate" (nodeOpCertFile args)
      , opt "--shelley-kes-key" (nodeKesKeyFile args)
      , opt "--shelley-vrf-key" (nodeVrfKeyFile args)
      ]

  opt :: a -> Maybe a -> [a]
  opt arg = \case
    Nothing -> []
    Just val -> [arg, val]

-- | Initialize the system start time to now (modulo a small offset needed to
-- give time to the system to bootstrap correctly).
initSystemStart :: IO UTCTime
initSystemStart = do
  addUTCTime 1 <$> getCurrentTime

-- | Re-generate configuration and genesis files with fresh system start times.
refreshSystemStart :: CardanoNodeConfig -> CardanoNodeArgs -> IO ()
refreshSystemStart cfg args = do
  let startTime = round @_ @Int . utcTimeToPOSIXSeconds $ systemStart cfg
  byronGenesis <-
    unsafeDecodeJsonFile (stateDirectory cfg </> nodeByronGenesisFile args)
      <&> addField "startTime" startTime

  let systemStartUTC =
        posixSecondsToUTCTime . fromRational . toRational $ startTime
  shelleyGenesis <-
    unsafeDecodeJsonFile (stateDirectory cfg </> nodeShelleyGenesisFile args)
      <&> addField "systemStart" systemStartUTC

  config <-
    unsafeDecodeJsonFile (stateDirectory cfg </> nodeConfigFile args)
      <&> addField "ByronGenesisFile" (nodeByronGenesisFile args)
      <&> addField "ShelleyGenesisFile" (nodeShelleyGenesisFile args)

  Aeson.encodeFile
    (stateDirectory cfg </> nodeByronGenesisFile args)
    byronGenesis
  Aeson.encodeFile
    (stateDirectory cfg </> nodeShelleyGenesisFile args)
    shelleyGenesis
  Aeson.encodeFile (stateDirectory cfg </> nodeConfigFile args) config

-- | Generate a topology file from a list of peers.
mkTopology :: [Port] -> Aeson.Value
mkTopology peers = do
  Aeson.object ["Producers" .= map encodePeer peers]
 where
  encodePeer :: Int -> Aeson.Value
  encodePeer port =
    Aeson.object
      ["addr" .= ("127.0.0.1" :: Text), "port" .= port, "valency" .= (1 :: Int)]

generateCardanoKey :: IO (VerificationKey PaymentKey, SigningKey PaymentKey)
generateCardanoKey = do
  sk <- generateSigningKey AsPaymentKey
  pure (getVerificationKey sk, sk)

data ProcessHasExited = ProcessHasExited Text ExitCode
  deriving (Show)

instance Exception ProcessHasExited

-- Logging

data NodeLog
  = MsgNodeCmdSpec Text
  | MsgCLI [Text]
  | MsgCLIStatus Text Text
  | MsgCLIRetry Text
  | MsgCLIRetryResult Text Int
  | MsgNodeStarting CardanoNodeConfig
  | MsgSocketIsReady FilePath
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

--
-- Helpers
--

addField :: ToJSON a => Aeson.Key -> a -> Aeson.Value -> Aeson.Value
addField k v = withObject (Aeson.KeyMap.insert k (toJSON v))

-- | Do something with an a JSON object. Fails if the given JSON value isn't an
-- object.
withObject :: (Aeson.Object -> Aeson.Object) -> Aeson.Value -> Aeson.Value
withObject fn = \case
  Aeson.Object m -> Aeson.Object (fn m)
  x -> x

unsafeDecodeJsonFile :: FromJSON a => FilePath -> IO a
unsafeDecodeJsonFile = Aeson.eitherDecodeFileStrict >=> either fail pure
