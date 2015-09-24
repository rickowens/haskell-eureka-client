{-# LANGUAGE NamedFieldPuns, OverloadedStrings #-}
module Network.Eureka.Types (
    EurekaConnection(..), EurekaConfig(..), InstanceConfig(..), InstanceInfo(..), InstanceStatus(..),
    AvailabilityZone, Region, DataCenterInfo(..), AmazonDataCenterInfo(..), IIRState(..),
    toNetworkName
    ) where

import Control.Concurrent        (ThreadId)
import Control.Concurrent.STM    (TVar)
import Network.HTTP.Client       (Manager)
import Control.Applicative ((<$>), (<*>))
import Control.Monad (mzero, (>=>))
import Data.Aeson (object, FromJSON(parseJSON), ToJSON(toJSON), Value(Object),
                   withObject, withText,
                   (.=), (.:), (.:?), (.!=))
import Data.Aeson.Types (Parser)
import Data.Default (Default(def))
import Data.Map (Map)
import Network.Socket (HostName)
import Text.Read (readMaybe)
import qualified Data.Aeson as Aeson (Value(String))
import qualified Data.Map as Map
import qualified Data.Text as T


type AvailabilityZone = String
type Region = String

data EurekaConnection = EurekaConnection {
      eConnEurekaConfig                 :: EurekaConfig
      -- ^ The configuration specifying where Eureka is.
    , eConnInstanceConfig               :: InstanceConfig
      -- ^ The configuration about this instance and how it will talk to Eureka.
    , eConnDataCenterInfo               :: DataCenterInfo
      -- ^ Datacenter info discovered at runtime.
    , eConnHeartbeatThread              :: ThreadId
      -- ^ Thread that periodically posts a heartbeat to Eureka so that it knows
      -- we're still alive.
    , eConnInstanceInfoReplicatorThread :: ThreadId
      -- ^ Thread that periodically pushes instance information to Eureka.
    , eConnManager                      :: Manager
      -- ^ HTTP manager that we use to make requests.
    , eConnHostname                     :: HostName
      -- ^ Base hostname gotten from the system at startup.
    , eConnHostIpv4                     :: String
      -- ^ IPv4 address we got for the above hostname at startup.
    , eConnStatus                       :: TVar InstanceStatus
      -- ^ Current status of this instance.
    }

instance Show EurekaConnection where
    show EurekaConnection {eConnEurekaConfig, eConnInstanceConfig,
                           eConnDataCenterInfo,
                           eConnHeartbeatThread,
                           eConnInstanceInfoReplicatorThread} =
        "EurekaConnection {eConnEurekaConfig=" ++ show eConnEurekaConfig ++
        ", eConnInstanceConfig=" ++ show eConnInstanceConfig ++
        ", eConnDataCenterInfo=" ++ show eConnDataCenterInfo ++
        ", eConnHeartbeatThread=" ++ show eConnHeartbeatThread ++
        ", eConnInstanceInfoReplicatorThread=" ++ show eConnInstanceInfoReplicatorThread ++
        "}"

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

instance Default EurekaConfig where
    def = EurekaConfig {
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
    , instanceVirtualHostname :: Maybe String
      -- ^ A possible override for the "virtual hostname" or VIP that you should
      -- use to access this instance. This hostname should have the form
      -- "hostname:port". If Nothing, just use hostname + secure port.
    , instanceSecureVirtualHostname :: Maybe String
      -- ^ A possible override for the "virtual hostname" or VIP that you should
      -- use to access this instance securely. This hostname should have the
      -- form "hostname:port". If Nothing, just use hostname + secure port.
    , instanceHostName :: Maybe HostName
      -- ^ The machine's hostname.
      -- If Nothing, use getHostName from Network.BSD.
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

-- | "IIR" stands for "instance info replicator", which is this thread's name
data IIRState = IIRState {
      iirLastAMIId :: Maybe String
      -- ^ The AMI ID of the coordinating server the last time we saw it.
      -- 'Nothing' on our first run.
    } deriving Show

instance Default IIRState where
    def = IIRState {
        iirLastAMIId = Nothing
        }

type AmazonInstanceType = String

data AmazonDataCenterInfo = 
  AmazonDataCenterInfo {
    amazonAmiId :: String ,
    amazonAmiLaunchIndex :: Integer ,
    amazonInstanceId :: String ,
    amazonInstanceType :: AmazonInstanceType ,
    amazonLocalIpv4 :: String ,
    amazonAvailabilityZone :: AvailabilityZone ,
    amazonPublicHostname :: String ,
    amazonPublicIpv4 :: String
  } deriving (Show)

data DataCenterInfo = DataCenterMyOwn
                    | DataCenterAmazon AmazonDataCenterInfo deriving Show

instance ToJSON DataCenterInfo where
    toJSON DataCenterMyOwn = object [
        "name" .= ("MyOwn" :: String)
        ]
    toJSON (DataCenterAmazon AmazonDataCenterInfo {
          amazonAmiId
        , amazonAmiLaunchIndex
        , amazonInstanceId
        , amazonInstanceType
        , amazonLocalIpv4
        , amazonAvailabilityZone
        , amazonPublicHostname
        , amazonPublicIpv4
        }) = object [
        "name" .= ("Amazon" :: String),
        "metadata" .= object [
            "ami-id" .= amazonAmiId,
            "ami-launch-index" .= amazonAmiLaunchIndex,
            "instance-type" .= amazonInstanceType,
            "instance-id" .= amazonInstanceId,
            "local-ipv4" .= amazonLocalIpv4,
            "availability-zone" .= amazonAvailabilityZone,
            "public-hostname" .= amazonPublicHostname,
            "public-ipv4" .= amazonPublicIpv4
            ]
        ]

instance FromJSON DataCenterInfo where
    parseJSON (Object v) = do
        name <- v .: "name"
        case name of
            "MyOwn" -> return DataCenterMyOwn
            "Amazon" -> do
                metadata <- v .: "metadata"
                DataCenterAmazon <$> (AmazonDataCenterInfo
                    <$> metadata .: "ami-id"
                    -- FIXME: should use Maybe?
                    <*> metadata .:? "ami-launch-index" .!= 0
                    <*> metadata .: "instance-type"
                    <*> metadata .: "instance-id"
                    <*> metadata .: "local-ipv4"
                    <*> metadata .: "availability-zone"
                    <*> metadata .: "public-hostname"
                    <*> metadata .: "public-ipv4"
                  )
            other -> fail $ "unknown datacenter info: " ++ other
    parseJSON _ = mzero

-- | Wire format for "instance infos".
--
-- This is all the information we need in order to register. Queries for other
-- instances also return these objects.
data InstanceInfo = InstanceInfo {
      instanceInfoHostName :: HostName
    , instanceInfoAppName :: String
    , instanceInfoIpAddr :: String
    , instanceInfoVipAddr :: String
    , instanceInfoSecureVipAddr :: String
    , instanceInfoStatus :: InstanceStatus
    , instanceInfoPort :: Int
    , instanceInfoSecurePort :: Int
    , instanceInfoHomePageUrl :: Maybe String
    , instanceInfoStatusPageUrl :: Maybe String
    , instanceInfoDataCenterInfo :: DataCenterInfo
    , instanceInfoMetadata :: Map String String
    , instanceInfoIsCoordinatingDiscoveryServer :: Bool
    } deriving Show

instance ToJSON InstanceInfo where
    toJSON InstanceInfo {
          instanceInfoHostName
        , instanceInfoAppName
        , instanceInfoIpAddr
        , instanceInfoVipAddr
        , instanceInfoSecureVipAddr
        , instanceInfoStatus
        , instanceInfoPort
        , instanceInfoSecurePort
        , instanceInfoHomePageUrl
        , instanceInfoStatusPageUrl
        , instanceInfoDataCenterInfo
        , instanceInfoMetadata
        , instanceInfoIsCoordinatingDiscoveryServer
        } = object [
        "hostName" .= instanceInfoHostName,
        "app" .= instanceInfoAppName,
        "ipAddr" .= instanceInfoIpAddr,
        "vipAddress" .= instanceInfoVipAddr,
        "secureVipAddress" .= instanceInfoSecureVipAddr,
        "status" .= instanceInfoStatus,
        "port" .= instanceInfoPort,
        "securePort" .= instanceInfoSecurePort,
        "homePageUrl" .= instanceInfoHomePageUrl,
        "statusPageUrl" .= instanceInfoStatusPageUrl,
        "dataCenterInfo" .= instanceInfoDataCenterInfo,
        "metadata" .= instanceInfoMetadata,
        "isCoordinatingDiscoveryServer" .= instanceInfoIsCoordinatingDiscoveryServer
        ]

instance FromJSON InstanceInfo where
    parseJSON (Object v) =
        InstanceInfo
            <$> v .: "hostName"
            <*> v .: "app"
            <*> v .: "ipAddr"
            <*> v .:? "vipAddress" .!= ""   -- FIXME: should vipAddr be Maybe?
            <*> v .:? "secureVipAddress" .!= ""
            <*> v .: "status"
            <*> (v .: "port" >>= parsePort)
            <*> (v .: "securePort" >>= parsePort)
            <*> v .:? "homePageUrl"
            <*> v .:? "statusPageUrl"
            <*> v .: "dataCenterInfo"
            <*> v .: "metadata"
            <*> v .:? "isCoordinatingDiscoveryServer" .!= False
      where
        parsePort :: Value -> Parser Int
        parsePort = withObject "port" (.: "$") >=> withText "portNumber" parseAsInt
        parseAsInt :: T.Text -> Parser Int
        parseAsInt t =
            maybe (fail $ "couldn't understand port number: " ++ s) return $ readMaybe s
          where
            s = T.unpack t
    parseJSON _ = mzero

instance Default InstanceConfig where
    def = InstanceConfig {
      instanceServiceUrlDefault = ""
    , instanceLeaseRenewalInterval = 30
    , instanceAppName = ""
    , instanceNonSecurePortEnabled = False
    , instanceSecurePortEnabled = False
    , instanceNonSecurePort = 80
    , instanceSecurePort = 443
    , instanceVirtualHostname = Nothing
    , instanceSecureVirtualHostname = Nothing
    , instanceHostName = Nothing
    , instanceStatusPageUrl = Nothing
    , instanceHomePageUrl = ""
    , instanceMetadata = Map.empty
    , instanceEnabledOnInit = True
    }

data InstanceStatus = Up | Down | Starting | OutOfService | Unknown
                    deriving (Show, Eq)

toNetworkName :: InstanceStatus -> String
toNetworkName Up = "UP"
toNetworkName Down = "DOWN"
toNetworkName Starting = "STARTING"
toNetworkName OutOfService = "OUT_OF_SERVICE"
toNetworkName Unknown = "UNKNOWN"

fromNetworkName :: (Monad m) => String -> m InstanceStatus
fromNetworkName "UP" = return Up
fromNetworkName "DOWN" = return Down
fromNetworkName "STARTING" = return Starting
fromNetworkName "OUT_OF_SERVICE" = return OutOfService
fromNetworkName "UNKNOWN" = return Unknown
fromNetworkName s = fail $ "unknown InstanceStatus: " ++ s

instance ToJSON InstanceStatus where
    -- N.B. OutOfService and Unknown aren't available according to the schema in
    -- https://github.com/Netflix/eureka/wiki/Eureka-REST-operations. What can
    -- we post in those cases?
    toJSON = Aeson.String . T.pack . toNetworkName

instance FromJSON InstanceStatus where
    parseJSON (Aeson.String text) = fromNetworkName (T.unpack text)
    parseJSON _ = mzero
