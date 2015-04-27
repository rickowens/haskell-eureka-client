module Network.Eureka.Metadata (
    addMetadata
  , lookupMetadata
  ) where

import qualified Data.Map                  as Map

import           Network.Eureka.Types      (InstanceConfig(InstanceConfig, instanceMetadata),
                                            InstanceInfo(InstanceInfo, instanceInfoMetadata))

-- | Adds a key-value pair to InstanceConfig's existing metadata.
addMetadata
  :: (String, String)
  -> InstanceConfig
  -> InstanceConfig
addMetadata (key, value) info@InstanceConfig{instanceMetadata = metadata}
  = info {instanceMetadata = Map.insert key value metadata}

-- | Looks up a value corresponding to a given key in InstanceConfig's metadata.
lookupMetadata
  :: String
  -> InstanceInfo
  -> Maybe String
lookupMetadata key InstanceInfo{instanceInfoMetadata = metadata}
  = Map.lookup key metadata
