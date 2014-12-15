import Network.Eureka (withEureka,
    EurekaConfig(eurekaInstanceInfoReplicationInterval, eurekaRegion,
                 eurekaServerServiceUrls,
                 eurekaAvailabilityZones), defaultEurekaConfig,
    InstanceConfig(instanceAppName, instanceLeaseRenewalInterval),
    DataCenterInfo(DataCenterMyOwn),
    defaultInstanceConfig)
import Control.Concurrent (threadDelay)
import System.Environment (getArgs)
import qualified Data.Map as Map

main :: IO ()
main = do
    args <- getArgs
    let [commandLineServer] = args
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
