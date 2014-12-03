module Network.Eureka (withEureka, EurekaConfig(..), InstanceConfig(..),
                       EurekaConnection) where

import Data.Map (Map)
import Control.Exception (bracket)

data EurekaConfig = EurekaConfiguration {
      eurekaServerServiceUrls :: Map String [String]
    }

data InstanceConfig = InstanceConfig {
      instanceSecurePortEnabled :: Bool
    , instanceServiceUrlDefault :: String
    , instanceName :: String
    , instancePort :: Int
    , instanceStatusPageUrl :: Maybe String
    , instanceHomePageUrl :: String
    }

data EurekaConnection = EurekaConnection

withEureka :: EurekaConfig -> InstanceConfig -> (EurekaConnection -> IO a) -> IO a
withEureka eConfig iConfig m = bracket (connectEureka eConfig) disconnectEureka (registerAndRun m)
  where
    registerAndRun m eConn = do
        registerInstance eConn iConfig
        m eConn

registerInstance :: EurekaConnection -> InstanceConfig -> IO ()
registerInstance _ _ = undefined

disconnectEureka :: EurekaConnection -> IO ()
disconnectEureka _ = undefined

connectEureka :: EurekaConfig -> IO EurekaConnection
connectEureka _ = undefined
