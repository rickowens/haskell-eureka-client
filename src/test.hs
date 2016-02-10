import Network.Eureka (withEureka,
    EurekaConfig(eurekaInstanceInfoReplicationInterval, eurekaRegion,
    eurekaServerServiceUrls), InstanceConfig(instanceAppName,
    instanceLeaseRenewalInterval, instanceMetadata),
    InstanceStatus(OutOfService), def, discoverDataCenterAmazon,
    lookupByAppName, setStatus, DataCenterInfo(DataCenterAmazon))
import Control.Concurrent (threadDelay)
import Control.Monad (replicateM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Logger (runNoLoggingT)
import Network.HTTP.Client (defaultManagerSettings, newManager)
import System.Environment (getArgs)
import qualified Data.Map as Map

main :: IO ()
main = do
    args <- getArgs
    let [commandLineServer] = args

    dataCenterInfo <- newManager defaultManagerSettings >>= discoverDataCenterAmazon
    runNoLoggingT $ withEureka
        (myEurekaConfig commandLineServer)
        myInstanceConfig
        (DataCenterAmazon dataCenterInfo)
        (\eConn -> runNoLoggingT $ do
            result <- lookupByAppName eConn "FITBIT-SYNC-WORKER"
            liftIO $ print result
            replicateM_ 10  delay
            setStatus eConn OutOfService
            replicateM_ 10  delay
          )
  where
    delay = liftIO $ threadDelay (1000 * 1000)
    myEurekaConfig serverUrl = def {
        eurekaInstanceInfoReplicationInterval = 1,
        eurekaServerServiceUrls = Map.fromList [("default", [serverUrl])],
        eurekaRegion = "default"
        }
    myInstanceConfig = def {
        instanceLeaseRenewalInterval = 1,
        instanceAppName = "haskell_eureka_test_app",
        instanceMetadata = Map.fromList [("testKey", "testValue")]
        }
