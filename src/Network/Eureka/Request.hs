{-# LANGUAGE NamedFieldPuns    #-}

module Network.Eureka.Request (
    makeRequest
  ) where

import           Control.Exception         (throw, try)
import           Control.Monad             (foldM)
import           Data.List                 (elemIndex, find, nub)
import qualified Data.Map                  as Map
import           Data.Maybe                (fromJust, fromMaybe)
import           Network.HTTP.Client       (HttpException (HandshakeFailed))

import           Network.Eureka.Types      (EurekaConnection(..),
                                            AmazonDataCenterInfo (..),
                                            AvailabilityZone,
                                            DataCenterInfo (..),
                                            EurekaConfig (..))


-- | Make a request of each of the available servers. In case a server fails,
-- try consecutive servers until one works (or we run out of servers). If all
-- servers fail, throw the last exception we got.
makeRequest
  :: EurekaConnection
  -> (String -> IO a)
  -> IO a
makeRequest conn@EurekaConnection {eConnEurekaConfig} action = do
    result <- foldM tryNext (Left HandshakeFailed) urls
    case result of
        Left bad -> throw bad
        Right good -> return good
  where
    urls = eurekaUrlsByProximity eConnEurekaConfig (availabilityZone conn)
    (Left _) `tryNext` nextUrl = try (action nextUrl)
    (Right good) `tryNext` _ = return (Right good)

    availabilityZone :: EurekaConnection -> AvailabilityZone
    availabilityZone EurekaConnection {
        eConnDataCenterInfo =
          DataCenterAmazon AmazonDataCenterInfo {amazonAvailabilityZone}
      } = amazonAvailabilityZone
    availabilityZone EurekaConnection {eConnEurekaConfig = eConfig} =
        head $ availabilityZonesFromConfig eConfig ++ ["default"]

    availabilityZonesFromConfig :: EurekaConfig -> [AvailabilityZone]
    availabilityZonesFromConfig EurekaConfig{eurekaAvailabilityZones, eurekaRegion} =
        fromMaybe
            -- If we don't have any listed for this region, there's always the
            -- "default" availability zone.
            ["default"]
            (Map.lookup eurekaRegion eurekaAvailabilityZones)

    -- | Provide a list of Eureka servers, with the ones in the same AZ as us first.
    -- Any of these Eureka servers are acceptable to maintain health in the face of
    -- failure, but the ones in the same zone have lower latency, so are preferred.
    eurekaUrlsByProximity :: EurekaConfig -> AvailabilityZone -> [String]
    eurekaUrlsByProximity eConfig thisZone =
        nub
        . concatMap (eurekaServerServiceUrlsForZone eConfig)
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
            -- If our current zone isn't present, try falling back to "default".
            Nothing -> case elemIndex "default" zones of
                Nothing -> error $ "couldn't find " ++ thisZone ++ " in zones " ++ show zones
                _ -> ["default"]
            -- fromJust is safe here because if the element is in the list, some
            -- rotation will put the element at the front.
            _ -> fromJust . find ((== thisZone) . head) . rotations $ zones
          where
            -- | Generate a list of rotations of a list.
            -- > rotations [1..4]
            -- [[1,2,3,4],[2,3,4,1],[3,4,1,2],[4,1,2,3]]
            rotations :: [a] -> [[a]]
            rotations lst = map (take (length lst) . flip drop (cycle lst)) [0..length lst - 1]

        eurekaServerServiceUrlsForZone :: EurekaConfig -> AvailabilityZone -> [String]
        eurekaServerServiceUrlsForZone EurekaConfig {eurekaServerServiceUrls} zone =
            fromMaybe
                (error $ "couldn't find any Eureka server URLs for zone " ++ show zone
                  ++ " in service config " ++ show eurekaServerServiceUrls)
                (Map.lookup zone eurekaServerServiceUrls)

