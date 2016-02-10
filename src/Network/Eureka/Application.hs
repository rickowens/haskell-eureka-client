{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}

module Network.Eureka.Application (
    lookupByAppName
  , lookupByAppNameAll
  , lookupAllApplications
  ) where

import           Control.Applicative       ((<$>))
import           Control.Exception         (catchJust)
import           Control.Monad             (mzero)
import           Data.Aeson                (FromJSON (parseJSON),
                                            Value (Object, Array), eitherDecode,
                                            (.:))
import           Data.Aeson.Types          (parseEither)
import           Data.Map                  (Map)
import qualified Data.Map                  as Map
import           Data.Text.Encoding        (encodeUtf8)
import qualified Data.Vector               as V
import           Network.HTTP.Client       (responseBody, httpLbs, Request(requestHeaders), HttpException(StatusCodeException))
import           Network.HTTP.Types.Status (Status(Status))

import Network.Eureka.Types (InstanceInfo(..), EurekaConnection(..), InstanceStatus(..))
import Network.Eureka.Util (parseUrlWithAdded)
import Network.Eureka.Request (makeRequest)

-- | Look up instance information for the given App Name.
-- NOTE: Only returns the instances which are up.
lookupByAppName
  :: EurekaConnection
  -> String
  -> IO [InstanceInfo]
lookupByAppName c n = filter isUp <$> lookupByAppNameAll c n
  where
    isUp = (==) Up . instanceInfoStatus

-- | Like @lookupByAppName@, but returns all instances, even DOWN and OUT_OF_SERVICE.
lookupByAppNameAll
  :: EurekaConnection
  -> String
  -> IO [InstanceInfo]
lookupByAppNameAll eConn@EurekaConnection { eConnManager } appName = do
    result <- makeRequest eConn getByAppName
    either error (return . applicationInstanceInfos) result
  where
    getByAppName url =
      catchJust
        only404s
        (do
          response <- eitherDecode . responseBody <$> httpLbs (request url) eConnManager
          return $ parseEither (.: "application") =<< response
        )
        (return . const (Right $ Application "" []))
    request url = requestJSON $ parseUrlWithAdded url $ "apps/" ++ appName
    only404s e@(StatusCodeException (Status 404 _) _ _) = Just e
    only404s _ = Nothing

{- |
  Returns all instances of all applications that eureka knows about,
  arranged by application name.
-}
lookupAllApplications
  :: EurekaConnection
  -> IO (Map String [InstanceInfo])
lookupAllApplications eConn@EurekaConnection {eConnManager} = do
    result <- makeRequest eConn getAllApps
    either error (return . toAppMap) result
  where
    getAllApps :: String -> IO (Either String Applications)
    getAllApps url =
      eitherDecode . responseBody <$> httpLbs request eConnManager
      where
        request = requestJSON (parseUrlWithAdded url "apps")

    toAppMap :: Applications -> Map String [InstanceInfo]
    toAppMap = Map.fromList . fmap appToTuple . applications

    appToTuple :: Application -> (String, [InstanceInfo])
    appToTuple (Application name infos) = (name, infos)

{- |
  Response type from Eureka "apps/" API.
-}
newtype Applications = Applications {applications :: [Application]}
instance FromJSON Applications where
  parseJSON (Object o) = do
    -- The design of the structured data coming out of Eureka is
    -- perplexing, to say the least.
    Object o2 <- o.: "applications"
    Array ary <- o2 .: "application"
    Applications <$> mapM parseJSON (V.toList ary)
  parseJSON v =
    fail (
      "Failed to parse list of all instances registered with \
      \Eureka. Bad value was " ++ show v ++ " when it should \
      \have been an object."
    )

-- | Response type from Eureka "apps/APP_NAME" API.
data Application = Application {
    _applicationName         :: String,
    applicationInstanceInfos :: [InstanceInfo]
    } deriving Show

instance FromJSON Application where
    parseJSON (Object v) = do
        name <- v .: "name"
        instanceOneOrMany <- v .: "instance"
        instanceData <- case instanceOneOrMany of
            (Array ary) -> mapM parseJSON (V.toList ary)
            o@(Object _) -> do
                instanceInfo <- parseJSON o
                return [instanceInfo]
            other -> fail $ "instance data was of a strange format: " ++ show other
        return $ Application name instanceData
    parseJSON _ = mzero


requestJSON :: Request -> Request
requestJSON r = r {
    requestHeaders = ("Accept", encodeUtf8 "application/json") : requestHeaders r
    }
