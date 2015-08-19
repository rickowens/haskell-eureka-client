{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Eureka (
  withEurekaH,
  withEureka,
  EurekaConfig(..),
  InstanceConfig(..),
  def,
  discoverDataCenterAmazon,
  setStatus,
  lookupByAppName,
  lookupAllApplications,
  InstanceInfo(..),
  InstanceStatus(..),
  DataCenterInfo(..),
  AmazonDataCenterInfo(..),
  EurekaConnection,
  AvailabilityZone,
  Region,
  addMetadata,
  lookupMetadata
) where

import           Control.Applicative       ((<$>), (<*>))
import qualified Data.ByteString.Lazy      as LBS
import           Data.Maybe                (fromJust)
import qualified Data.Text                 as T
import           Data.Text.Encoding        (decodeUtf8)
import           Data.Default              (def)
import           Network.Eureka.Types      (AmazonDataCenterInfo (..),
                                            AvailabilityZone,
                                            DataCenterInfo (..),
                                            EurekaConfig (..),
                                            InstanceConfig (..),
                                            InstanceInfo (..),
                                            InstanceStatus (..), Region)
import           Network.HTTP.Client       (Manager, responseBody, parseUrl, httpLbs)

import Network.Eureka.Application (lookupByAppName, lookupAllApplications)
import Network.Eureka.Connection (withEureka, withEurekaH, setStatus, EurekaConnection)
import Network.Eureka.Metadata (addMetadata, lookupMetadata)

-- | Interrogate the magical URL http://169.254.169.254/latest/meta-data to
-- fill in an DataCenterAmazon.
discoverDataCenterAmazon :: Manager -> IO AmazonDataCenterInfo
discoverDataCenterAmazon manager =
    AmazonDataCenterInfo <$>
        getMeta "ami-id" <*>
        (read <$> getMeta "ami-launch-index") <*>
        getMeta "instance-id" <*>
        getMeta "instance-type" <*>
        getMeta "local-ipv4" <*>
        getMeta "placement/availability-zone" <*>
        getMeta "public-hostname" <*>
        getMeta "public-ipv4"
  where
    getMeta :: String -> IO String
    getMeta pathName = fromBS . responseBody <$> httpLbs metaRequest manager
      where
        metaRequest = fromJust . parseUrl $ "http://169.254.169.254/latest/meta-data/" ++ pathName
        fromBS = T.unpack . decodeUtf8 . LBS.toStrict

