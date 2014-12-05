import Network.Eureka (withEureka,
    EurekaConfig(eurekaInstanceInfoReplicationInterval), defaultEurekaConfig,
    InstanceConfig(instanceLeaseRenewalInterval), defaultInstanceConfig)
import Control.Concurrent (threadDelay)

main = withEureka myEurekaConfig myInstanceConfig $ \_ -> do
    sequence_ $ replicate 20 $ threadDelay $ 1000 * 1000
  where
    myEurekaConfig = defaultEurekaConfig { eurekaInstanceInfoReplicationInterval = 1 }
    myInstanceConfig = defaultInstanceConfig { instanceLeaseRenewalInterval = 1 }
