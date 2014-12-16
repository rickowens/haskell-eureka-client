import Network.Eureka (withEureka,
    EurekaConfig(eurekaInstanceInfoReplicationInterval, eurekaRegion,
                 eurekaServerServiceUrls,
                 eurekaAvailabilityZones), defaultEurekaConfig,
    InstanceConfig(instanceAppName, instanceLeaseRenewalInterval),
    DataCenterInfo(DataCenterMyOwn),
    defaultInstanceConfig)
import Control.Applicative ((<$>))
import Control.Concurrent (threadDelay)
import System.Environment (getArgs)
import System.IO (stdout)
import System.Log.Formatter (simpleLogFormatter)
import System.Log.Handler (setFormatter)
import System.Log.Handler.Simple (streamHandler)
import System.Log.Logger (setLevel, setHandlers, updateGlobalLogger, Priority(DEBUG))
import qualified Data.Map as Map

main :: IO ()
main = do
    args <- getArgs
    let [commandLineServer] = args
        level = DEBUG
    console <- tweak <$> streamHandler stdout level
    let handlers = [console]
    updateGlobalLogger "" (setLevel level . setHandlers handlers)

    withEureka (myEurekaConfig commandLineServer) myInstanceConfig DataCenterMyOwn $ \_ -> do
        sequence_ $ replicate 20 $ threadDelay $ 1000 * 1000
  where
    myEurekaConfig serverUrl = defaultEurekaConfig {
        eurekaInstanceInfoReplicationInterval = 1,
        eurekaServerServiceUrls = Map.fromList [("us-east-1a", [serverUrl])],
        eurekaAvailabilityZones = Map.fromList [("us-east-1", ["us-east-1a"])],
        eurekaRegion = "us-east-1"
        }
    myInstanceConfig = defaultInstanceConfig {
        instanceLeaseRenewalInterval = 1,
        instanceAppName = "haskell_eureka_test_app"
        }
    tweak h = setFormatter h (simpleLogFormatter logFormat)
    logFormat = "$prio [$tid] [$time] $loggername - $msg"
