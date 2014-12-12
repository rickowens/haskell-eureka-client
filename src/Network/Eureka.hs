{-# LANGUAGE NamedFieldPuns #-}
module Network.Eureka (withEureka, EurekaConfig(..), InstanceConfig(..),
                       defaultEurekaConfig, defaultInstanceConfig,
                       defaultInstanceInfo,
                       EurekaConnection, AvailabilityZone, Region) where

import Data.List (elemIndex, find, nub)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (formatTime, parseTime)
import Data.Map (Map, (!))
import Data.Maybe (fromJust)
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Exception (bracket, throw, try)
import Control.Monad (foldM)
import Control.Monad.Fix (mfix)
import Network.HTTP.Client (HttpException(HandshakeFailed))
import System.Locale (defaultTimeLocale)
import qualified Data.Map as Map

type AvailabilityZone = String
type Region = String

data EurekaConfig = EurekaConfig {
      eurekaServerServiceUrls :: Map AvailabilityZone [String]
      -- ^ The URLs for Eureka, per availability zone.
    , eurekaInstanceInfoReplicationInterval :: Int
      -- ^ How often, in seconds, to push instance info to Eureka.
    , eurekaAvailabilityZones :: Map Region [AvailabilityZone]
      -- ^ Availability zones that we run in, indexed by region.
    , eurekaRegion :: Region
      -- ^ The region we are running in.
    } deriving Show

defaultEurekaConfig = EurekaConfig {
      eurekaServerServiceUrls = Map.empty
    , eurekaInstanceInfoReplicationInterval = 30
    , eurekaAvailabilityZones = Map.empty
    , eurekaRegion = ""
    }

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

type AmazonInstanceType = String

data DataCenterInfo = DataCenterMyOwn
                    | DataCenterAmazon {
      amazonAmiId :: String
    , amazonInstanceId :: String
    , amazonInstanceType :: AmazonInstanceType
    , amazonLocalIpv4 :: String
    , amazonAvailabilityZone :: AvailabilityZone
    , amazonPublicHostname :: String
    , amazonPublicIpv4 :: String
    } deriving Show

data InstanceInfo = InstanceInfo {
      instanceDataCenterInfo :: DataCenterInfo
      -- ^ Info about what data center this instance is running in.
    } deriving Show

defaultInstanceInfo = InstanceInfo {
      instanceDataCenterInfo = DataCenterMyOwn
    }

defaultInstanceConfig = InstanceConfig {
      instanceServiceUrlDefault = ""
    , instanceLeaseRenewalInterval = 30
    , instanceName = ""
    , instanceNonSecurePortEnabled = False
    , instanceSecurePortEnabled = False
    , instanceNonSecurePort = 80
    , instanceSecurePort = 443
    , instanceStatusPageUrl = Nothing
    , instanceHomePageUrl = ""
    , instanceMetadata = Map.empty
    , instanceEnabledOnInit = True
    }

data EurekaConnection = EurekaConnection {
      eConnEurekaConfig :: EurekaConfig
      -- ^ The configuration specifying where Eureka is.
    , eConnInstanceConfig :: InstanceConfig
      -- ^ The configuration about this instance and how it will talk to Eureka.
    , eConnInstanceInfo :: InstanceInfo
      -- ^ Info about this instance as discovered at runtime.
    , eConnHeartbeatThread :: ThreadId
      -- ^ Thread that periodically posts a heartbeat to Eureka so that it knows
      -- we're still alive.
    , eConnInstanceInfoReplicatorThread :: ThreadId
      -- ^ Thread that periodically pushes instance information to Eureka.
    } deriving Show

withEureka :: EurekaConfig -> InstanceConfig -> InstanceInfo
           -> (EurekaConnection -> IO a) -> IO a
withEureka eConfig iConfig iInfo m =
    bracket (connectEureka eConfig iConfig iInfo) disconnectEureka (registerAndRun m)
  where
    registerAndRun m eConn = do
        registerInstance eConn iConfig
        m eConn

-- | Provide a list of Eureka servers, with the ones in the same AZ as us first.
-- Any of these Eureka servers are acceptable to maintain health in the face of
-- failure, but the ones in the same zone have lower latency, so are preferred.
eurekaUrlsByProximity :: EurekaConfig -> AvailabilityZone -> [String]
eurekaUrlsByProximity EurekaConfig {
    eurekaRegion, eurekaServerServiceUrls, eurekaAvailabilityZones} thisZone =
    nub
    . concat
    . map (eurekaServerServiceUrls !)
    . thisZoneFirst
    . (eurekaAvailabilityZones !)
    $ eurekaRegion
  where
    -- | Return the rotation of the list of availability zones that has this
    -- current zone first.
    --
    -- Rotations are used rather than just pulling the present zone to the front
    -- of the list because this is the algorithm that the Java Eureka client
    -- uses to order availability zones. Presumably this is to try to not
    -- dogpile servers in the first availability zone in case of failure.
    thisZoneFirst :: [AvailabilityZone] -> [AvailabilityZone]
    thisZoneFirst zones = case elemIndex thisZone zones of
        Nothing -> error $ "couldn't find " ++ thisZone ++ " in zones " ++ show zones
        -- fromJust is safe here because if the element is in the list, some
        -- rotation will put the element at the front.
        _ -> fromJust . find ((== thisZone) . head) . rotations $ zones

registerInstance :: EurekaConnection -> InstanceConfig -> IO ()
registerInstance _ _ = return ()

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

connectEureka :: EurekaConfig -> InstanceConfig -> InstanceInfo -> IO EurekaConnection
connectEureka
    eConfig@EurekaConfig{
        eurekaInstanceInfoReplicationInterval=instanceInfoInterval
        }
    iConfig@InstanceConfig{
        instanceLeaseRenewalInterval=heartbeatInterval
        } instanceInfo = mfix $ \econn -> do
    heartbeatThreadId <- forkIO . heartbeatThread $ econn
    instanceInfoThreadId <- forkIO . instanceInfoThread $ econn
    return EurekaConnection {
          eConnEurekaConfig = eConfig
        , eConnInstanceConfig = iConfig
        , eConnInstanceInfo = instanceInfo
        , eConnHeartbeatThread = heartbeatThreadId
        , eConnInstanceInfoReplicatorThread = instanceInfoThreadId
        }
  where
    heartbeatThread :: EurekaConnection -> IO ()
    heartbeatThread = repeating heartbeatInterval . postHeartbeat
    instanceInfoThread = repeating instanceInfoInterval . updateInstanceInfo

-- | Make a request of each of the available servers. In case a server fails,
-- try consecutive servers until one works (or we run out of servers). If all
-- servers fail, throw the last exception we got.
makeRequest :: EurekaConnection -> (String -> IO a) -> IO a
makeRequest conn@EurekaConnection {eConnEurekaConfig, eConnInstanceConfig}
    action = do
    result <- foldM tryNext (Left HandshakeFailed) urls
    case result of
        Left bad -> throw bad
        Right good -> return good
  where
    urls = eurekaUrlsByProximity eConnEurekaConfig "FIXME: get current zone"
    (Left bad) `tryNext` nextUrl = try (action nextUrl)
    (Right good) `tryNext` nextUrl = return (Right good)


-- | Perform an action every 'delay' seconds.
-- Delays are not exact; we use threadDelay to schedule the repetition.
repeating :: Int -> IO () -> IO ()
repeating i a = loop
  where
    loop = do
        a
        threadDelay (i * 1000 * 1000)
        loop

-- | Generate a list of rotations of a list.
-- > rotations [1..4]
-- [[1,2,3,4],[2,3,4,1],[3,4,1,2],[4,1,2,3]]
rotations :: [a] -> [[a]]
rotations lst = map (take (length lst) . flip drop (cycle lst)) $ [0..length lst - 1]
