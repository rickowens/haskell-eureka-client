{-# LANGUAGE NamedFieldPuns, OverloadedStrings #-}
module Network.Eureka.Types (
    EurekaConfig(..), InstanceConfig(..), InstanceInfo(..), InstanceStatus(..),
    AvailabilityZone, Region, DataCenterInfo(..),
    toNetworkName,
    ) where

import Control.Applicative ((<$>), (<*>))
import Control.Monad (mzero)
import Data.Aeson (object, FromJSON(parseJSON), ToJSON(toJSON), Value(Object),
                   (.=), (.:))
import Data.Default (Default(def))
import Data.Map (Map)
import Network.Socket (HostName)
import qualified Data.Aeson as Aeson (Value(String))
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
    , amazonAmiLaunchIndex :: String
    , amazonInstanceId :: String
    , amazonInstanceType :: AmazonInstanceType
    , amazonLocalIpv4 :: String
    , amazonAvailabilityZone :: AvailabilityZone
    , amazonPublicHostname :: String
    , amazonPublicIpv4 :: String
    } deriving Show

instance ToJSON DataCenterInfo where
    toJSON DataCenterMyOwn = object [
        "name" .= ("MyOwn" :: String)
        ]
    toJSON DataCenterAmazon {
          amazonAmiId
        , amazonAmiLaunchIndex
        , amazonInstanceId
        , amazonInstanceType
        , amazonLocalIpv4
        , amazonAvailabilityZone
        , amazonPublicHostname
        , amazonPublicIpv4
        } = object [
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
                DataCenterAmazon
                    <$> metadata .: "ami-id"
                    <*> metadata .: "ami-launch-index"
                    <*> metadata .: "instance-type"
                    <*> metadata .: "instance-id"
                    <*> metadata .: "local-ipv4"
                    <*> metadata .: "availability-zone"
                    <*> metadata .: "public-hostname"
                    <*> metadata .: "public-ipv4"
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
    , instanceInfoDataCenterInfo :: DataCenterInfo
    , instanceInfoMetadata :: Map String String
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
        , instanceInfoDataCenterInfo
        , instanceInfoMetadata
        } = object [
        "hostName" .= instanceInfoHostName,
        "app" .= instanceInfoAppName,
        "ipAddr" .= instanceInfoIpAddr,
        "vipAddr" .= instanceInfoVipAddr,
        "secureVipAddr" .= instanceInfoSecureVipAddr,
        "status" .= instanceInfoStatus,
        "port" .= instanceInfoPort,
        "securePort" .= instanceInfoSecurePort,
        "dataCenterInfo" .= instanceInfoDataCenterInfo,
        "metadata" .= instanceInfoMetadata
        ]

instance FromJSON InstanceInfo where
    parseJSON (Object v) =
        InstanceInfo
            <$> v .: "hostname"
            <*> v .: "app"
            <*> v .: "ipAddr"
            <*> v .: "vipAddr"
            <*> v .: "secureVipAddr"
            <*> v .: "status"
            <*> v .: "port"
            <*> v .: "securePort"
            <*> v .: "dataCenterInfo"
            <*> v .: "metadata"
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
    , instanceStatusPageUrl = Nothing
    , instanceHomePageUrl = ""
    , instanceMetadata = Map.empty
    , instanceEnabledOnInit = True
    }

data InstanceStatus = Up | Down | Starting | OutOfService | Unknown
                    deriving Show

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
