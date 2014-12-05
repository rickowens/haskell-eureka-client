{-# LANGUAGE NamedFieldPuns #-}
module Network.Eureka (withEureka, EurekaConfig(..), InstanceConfig(..),
                       EurekaConnection) where

import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (formatTime, parseTime)
import Data.Map (Map)
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Exception (bracket)
import Control.Monad.Fix (mfix)
import System.Locale (defaultTimeLocale)
import qualified Data.Map as Map

data EurekaConfig = EurekaConfig {
      eurekaServerServiceUrls :: Map String [String]
      -- ^ The URLs for Eureka, per availability zone.
    , eurekaInstanceInfoReplicationInterval :: Int
      -- ^ How often, in seconds, to push instance info to Eureka.
    } deriving Show

data InstanceConfig = InstanceConfig {
      instanceServiceUrlDefault :: String
      -- ^ What URL to use to access the service.
    , instanceLeaseRenewalInterval :: Int
      -- ^ How often, in seconds, to send heartbeat updates.
    , instanceName :: String
      -- ^ The name of the service.
    , instanceNonSecurePortEnabled :: Bool
      -- ^ True if this instance can be accessed over an insecure port.
    , instanceSecurePortEnabled :: Bool
      -- ^ True if this instance can be accessed over a secure port (https).
    , instanceNonSecurePort :: Int
      -- ^ Port number that you can use to access this instance if security
      -- isn't a concern.
    , instanceSecurePort :: Int
      -- ^ Port number that you can use to access this instance securely.
    , instanceStatusPageUrl :: Maybe String
      -- ^ URL to use to access this instance's status page.
    , instanceHomePageUrl :: String
      -- ^ URL to use to access this instance's home page.
    , instanceMetadata :: Map String String
      --  ^ A map of metadata about this instance.
    , instanceEnabledOnInit :: Bool
      -- ^ Whether the instance should be marked as "up" immediately.  Some
      -- services might not be ready at startup, in which case this should be
      -- false.
    } deriving Show

data EurekaConnection = EurekaConnection {
      eConnEurekaConfig :: EurekaConfig
      -- ^ The configuration specifying where Eureka is.
    , eConnInstanceConfig :: InstanceConfig
      -- ^ The configuration about this instance and how it will talk to Eureka.
    , eConnHeartbeatThread :: ThreadId
      -- ^ Thread that periodically posts a heartbeat to Eureka so that it knows
      -- we're still alive.
    , eConnInstanceInfoReplicatorThread :: ThreadId
      -- ^ Thread that periodically pushes instance information to Eureka.
    } deriving Show

withEureka :: EurekaConfig -> InstanceConfig -> (EurekaConnection -> IO a) -> IO a
withEureka eConfig iConfig m = bracket (connectEureka eConfig iConfig) disconnectEureka (registerAndRun m)
  where
    registerAndRun m eConn = do
        registerInstance eConn iConfig
        m eConn

registerInstance :: EurekaConnection -> InstanceConfig -> IO ()
registerInstance _ _ = undefined

disconnectEureka :: EurekaConnection -> IO ()
disconnectEureka _ = undefined

formatISO8601 :: UTCTime -> String
formatISO8601 t = formatTime defaultTimeLocale "%FT%T%QZ" t

postHeartbeat :: EurekaConnection -> IO ()
postHeartbeat conn = do
    now <- getCurrentTime
    print $ "Posting heartbeat " ++ show conn ++ " at " ++ formatISO8601 now

updateInstanceInfo :: EurekaConnection -> IO ()
updateInstanceInfo conn = do
    now <- getCurrentTime
    print $ "Updating instance info " ++ show conn ++ " at " ++ formatISO8601 now

connectEureka :: EurekaConfig -> InstanceConfig -> IO EurekaConnection
connectEureka
    eConfig@EurekaConfig{
        eurekaInstanceInfoReplicationInterval=instanceInfoInterval
        }
    iConfig@InstanceConfig{
        instanceLeaseRenewalInterval=heartbeatInterval
        } = mfix $ \econn -> do
    heartbeatThreadId <- forkIO . heartbeatThread $ econn
    instanceInfoThreadId <- forkIO . instanceInfoThread $ econn
    return EurekaConnection {
          eConnEurekaConfig = eConfig
        , eConnInstanceConfig = iConfig
        , eConnHeartbeatThread = heartbeatThreadId
        , eConnInstanceInfoReplicatorThread = instanceInfoThreadId
        }
  where
    heartbeatThread :: EurekaConnection -> IO ()
    heartbeatThread = repeating heartbeatInterval . postHeartbeat
    instanceInfoThread = repeating instanceInfoInterval . updateInstanceInfo

-- | Perform an action every 'delay' seconds.
-- Delays are not exact; we use threadDelay to schedule the repetition.
repeating :: Int -> IO () -> IO ()
repeating i a = loop
  where
    loop = do
        a
        threadDelay (i * 1000 * 1000)
        loop
