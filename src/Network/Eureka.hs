{-# LANGUAGE NamedFieldPuns, OverloadedStrings #-}
module Network.Eureka (withEureka, EurekaConfig(..), InstanceConfig(..),
                       defaultEurekaConfig, defaultInstanceConfig,
                       defaultInstanceInfo,
                       EurekaConnection, AvailabilityZone, Region) where

import Data.List (elemIndex, find, nub)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (formatTime, parseTime)
import Data.Map (Map, (!))
import Data.Maybe (fromJust)
import Data.Text.Encoding (encodeUtf8)
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Exception (bracket, throw, try)
import Control.Monad (foldM)
import Control.Monad.Fix (mfix)
import Network.HTTP.Client (HttpException(HandshakeFailed), Manager,
                            RequestBody(RequestBodyBS),
                            Request(method, requestBody, requestHeaders),
                            defaultManagerSettings,
                            parseUrl,
                            withManager, withResponse)
import Network.HTTP.Types.Method (methodPost)
import System.Locale (defaultTimeLocale)
import qualified Data.Map as Map
import qualified Data.Text as T

type AvailabilityZone = String
type Region = String

-- | Configuration necessary to speak to a Eureka server.  This corresponds to
-- the EurekaClientConfig class in Netflix's implementation.
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

defaultEurekaConfig :: EurekaConfig
defaultEurekaConfig = EurekaConfig {
      eurekaServerServiceUrls = Map.empty
    , eurekaInstanceInfoReplicationInterval = 30
    , eurekaAvailabilityZones = Map.empty
    , eurekaRegion = ""
    }

-- | Configuration about this instance.  This corresponds to the
-- EurekaInstanceConfig class in Netflix's implementation.
data InstanceConfig = InstanceConfig {
      instanceServiceUrlDefault :: String
      -- ^ What URL to use to access the service.
    , instanceLeaseRenewalInterval :: Int
      -- ^ How often, in seconds, to send heartbeat updates.
    , instanceAppName :: String
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

defaultInstanceInfo :: InstanceInfo
defaultInstanceInfo = InstanceInfo {
      instanceDataCenterInfo = DataCenterMyOwn
    }

defaultInstanceConfig :: InstanceConfig
defaultInstanceConfig = InstanceConfig {
      instanceServiceUrlDefault = ""
    , instanceLeaseRenewalInterval = 30
    , instanceAppName = ""
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
    , eConnManager :: Manager
      -- ^ HTTP manager that we use to make requests.
    }

instance Show EurekaConnection where
    show EurekaConnection {eConnEurekaConfig, eConnInstanceConfig,
                           eConnInstanceInfo, eConnHeartbeatThread,
                           eConnInstanceInfoReplicatorThread} =
        "EurekaConnection {eConnEurekaConfig=" ++ show eConnEurekaConfig ++
        ", eConnInstanceConfig=" ++ show eConnInstanceConfig ++
        ", eConnInstanceInfo=" ++ show eConnInstanceInfo ++
        ", eConnHeartbeatThread=" ++ show eConnHeartbeatThread ++
        ", eConnInstanceInfoReplicatorThread=" ++ show eConnInstanceInfoReplicatorThread ++
        "}"

withEureka :: EurekaConfig -> InstanceConfig -> InstanceInfo
           -> (EurekaConnection -> IO a) -> IO a
withEureka eConfig iConfig iInfo m =
    withManager defaultManagerSettings $ \manager ->
    bracket (connectEureka manager eConfig iConfig iInfo) disconnectEureka registerAndRun
  where
    registerAndRun eConn = do
        registerInstance eConn
        m eConn

-- | Provide a list of Eureka servers, with the ones in the same AZ as us first.
-- Any of these Eureka servers are acceptable to maintain health in the face of
-- failure, but the ones in the same zone have lower latency, so are preferred.
eurekaUrlsByProximity :: EurekaConfig -> AvailabilityZone -> [String]
eurekaUrlsByProximity eConfig thisZone =
    nub
    . concat
    . map (eurekaServerServiceUrlsForZone eConfig)
    . thisZoneFirst
    . availabilityZonesFromConfig
    $ eConfig
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

registerInstance :: EurekaConnection -> IO ()
registerInstance eConn@EurekaConnection { eConnManager,
        eConnInstanceConfig = InstanceConfig {instanceAppName}
    } = makeRequest eConn sendRegister
  where
    sendRegister url = withResponse (registerRequest url) eConnManager $ \_ -> do
        return ()
    registerRequest url = request {
          method = methodPost
        , requestHeaders = [("Content-Type", "application/json")]
        , requestBody = RequestBodyBS $ encodeUtf8 $ T.pack "{}"
        }
      where
        request = fromJust $ parseUrl (addPath url "apps/" ++ instanceAppName)

-- | Add an additional path fragment to a base URL.
--
-- I tried doing this using the http-types library but it was just so
-- inconvenient that I fell back to doing it this way. Alternative
-- implementations welcomed.
addPath :: String -> String -> String
addPath base additional = baseWithSlash ++ additional
  where
    baseWithSlash = if last base == '/' then base else base ++ "/"

disconnectEureka :: EurekaConnection -> IO ()
disconnectEureka _ = return ()

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

connectEureka :: Manager
              -> EurekaConfig -> InstanceConfig -> InstanceInfo
              -> IO EurekaConnection
connectEureka manager
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
        , eConnManager = manager
        }
  where
    heartbeatThread :: EurekaConnection -> IO ()
    heartbeatThread = repeating heartbeatInterval . postHeartbeat
    instanceInfoThread = repeating instanceInfoInterval . updateInstanceInfo

-- | Make a request of each of the available servers. In case a server fails,
-- try consecutive servers until one works (or we run out of servers). If all
-- servers fail, throw the last exception we got.
makeRequest :: EurekaConnection -> (String -> IO a) -> IO a
makeRequest conn@EurekaConnection {eConnEurekaConfig}
    action = do
    result <- foldM tryNext (Left HandshakeFailed) urls
    case result of
        Left bad -> throw bad
        Right good -> return good
  where
    urls = eurekaUrlsByProximity eConnEurekaConfig (availabilityZone conn)
    (Left _) `tryNext` nextUrl = try (action nextUrl)
    (Right good) `tryNext` _ = return (Right good)

availabilityZonesFromConfig :: EurekaConfig -> [AvailabilityZone]
availabilityZonesFromConfig EurekaConfig{eurekaAvailabilityZones, eurekaRegion} =
    case Map.lookup eurekaRegion eurekaAvailabilityZones of
        Nothing -> error $ "couldn't find region " ++ show eurekaRegion
                           ++ " in zones config " ++ show eurekaAvailabilityZones
        Just zones -> zones

eurekaServerServiceUrlsForZone :: EurekaConfig -> AvailabilityZone -> [String]
eurekaServerServiceUrlsForZone EurekaConfig {eurekaServerServiceUrls} zone =
    case Map.lookup zone eurekaServerServiceUrls of
        Nothing -> error $ "couldn't find any Eureka server URLs for zone " ++ show zone
                           ++ " in service config " ++ show eurekaServerServiceUrls
        Just urls -> urls

availabilityZone :: EurekaConnection -> AvailabilityZone
availabilityZone EurekaConnection {
    eConnInstanceInfo = InstanceInfo {
        instanceDataCenterInfo = DataCenterAmazon {amazonAvailabilityZone}
        }
    } = amazonAvailabilityZone
availabilityZone EurekaConnection {eConnEurekaConfig} =
    head $ availabilityZonesFromConfig eConnEurekaConfig ++ ["default"]



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
