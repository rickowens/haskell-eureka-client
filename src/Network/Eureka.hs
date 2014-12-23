{-# LANGUAGE NamedFieldPuns, OverloadedStrings #-}
module Network.Eureka (withEureka, EurekaConfig(..), InstanceConfig(..),
                       def,
                       discoverDataCenterAmazon, setStatus,
                       lookupByAppName,
                       InstanceStatus(..),
                       DataCenterInfo(DataCenterMyOwn),
                       EurekaConnection, AvailabilityZone, Region) where

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.STM (TVar, atomically, newTVar, readTVar, writeTVar)
import Control.Exception (bracket, throw, try, SomeException)
import Control.Monad (foldM, mzero, when)
import Control.Monad.Fix (mfix)
import Data.Aeson (eitherDecode, encode, object, (.=), (.:),
                   FromJSON(parseJSON),
                   Value(Object, Array))
import Data.Aeson.Types (parseEither)
import Data.Default (Default,
                     def)  -- re-export for convenience
import Data.List (elemIndex, find, nub)
import Data.Maybe (fromJust, fromMaybe, isNothing)
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Network.BSD (getHostName)
import Network.Eureka.Types (InstanceInfo(..), EurekaConfig(..),
                             InstanceConfig(..), InstanceStatus(..),
                             AvailabilityZone, Region, DataCenterInfo(..),
                             toNetworkName)
import Network.Socket (AddrInfo(addrAddress, addrFamily),
                       Family(AF_INET), HostName, NameInfoFlag(NI_NUMERICHOST),
                       defaultHints, getAddrInfo, getNameInfo)
import Network.HTTP.Client (HttpException(HandshakeFailed), Manager,
                            RequestBody(RequestBodyLBS),
                            Request(checkStatus, method, requestBody,
                                    requestHeaders),
                            defaultManagerSettings, httpLbs,
                            parseUrl, queryString,
                            responseStatus, responseBody,
                            withManager, withResponse)
import Network.HTTP.Types.Method (methodDelete, methodPost, methodPut)
import Network.HTTP.Types.Status (status404)
import System.Log.Logger (debugM, errorM, infoM)
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Map as Map
import qualified Data.Text as T
import qualified Data.Vector as V

-- | Interrogate the magical URL http://169.254.169.254/latest/meta-data to
-- fill in an DataCenterAmazon.
discoverDataCenterAmazon :: Manager -> IO DataCenterInfo
discoverDataCenterAmazon manager =
    DataCenterAmazon <$>
        getMeta "ami-id" <*>
        getMeta "ami-launch-index" <*>
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

data EurekaConnection = EurekaConnection {
      eConnEurekaConfig :: EurekaConfig
      -- ^ The configuration specifying where Eureka is.
    , eConnInstanceConfig :: InstanceConfig
      -- ^ The configuration about this instance and how it will talk to Eureka.
    , eConnDataCenterInfo :: DataCenterInfo
      -- ^ Datacenter info discovered at runtime.
    , eConnHeartbeatThread :: ThreadId
      -- ^ Thread that periodically posts a heartbeat to Eureka so that it knows
      -- we're still alive.
    , eConnInstanceInfoReplicatorThread :: ThreadId
      -- ^ Thread that periodically pushes instance information to Eureka.
    , eConnManager :: Manager
      -- ^ HTTP manager that we use to make requests.
    , eConnHostname :: HostName
      -- ^ Base hostname gotten from the system at startup.
    , eConnHostIpv4 :: String
      -- ^ IPv4 address we got for the above hostname at startup.
    , eConnStatus :: TVar InstanceStatus
      -- ^ Current status of this instance.
    }

instance Show EurekaConnection where
    show EurekaConnection {eConnEurekaConfig, eConnInstanceConfig,
                           eConnDataCenterInfo,
                           eConnHeartbeatThread,
                           eConnInstanceInfoReplicatorThread} =
        "EurekaConnection {eConnEurekaConfig=" ++ show eConnEurekaConfig ++
        ", eConnInstanceConfig=" ++ show eConnInstanceConfig ++
        ", eConnDataCenterInfo=" ++ show eConnDataCenterInfo ++
        ", eConnHeartbeatThread=" ++ show eConnHeartbeatThread ++
        ", eConnInstanceInfoReplicatorThread=" ++ show eConnInstanceInfoReplicatorThread ++
        "}"

withEureka :: EurekaConfig -> InstanceConfig -> DataCenterInfo
           -> (EurekaConnection -> IO a) -> IO a
withEureka eConfig iConfig iInfo m =
    withManager defaultManagerSettings $ \manager ->
    bracket (connectEureka manager eConfig iConfig iInfo) disconnectEureka registerAndRun
  where
    registerAndRun eConn = do
        registerInstance eConn
        m eConn

lookupByAppName :: EurekaConnection -> String -> IO [InstanceInfo]
lookupByAppName eConn@EurekaConnection { eConnManager } appName = do
    result <- makeRequest eConn getByAppName
    either error (return . applicationInstanceInfos) result
  where
    getByAppName url = do
        response <- eitherDecode . responseBody <$> httpLbs (request url) eConnManager
        return $ parseEither (.: "application") =<< response
    request url = requestJSON $ parseUrlWithAdded url $ "apps/" ++ appName

-- | Response type from Eureka "apps/APP_NAME" API.
data Application = Application {
    _applicationName :: String,
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

setStatus :: EurekaConnection -> InstanceStatus -> IO ()
setStatus eConn@EurekaConnection { eConnManager, eConnStatus } newStatus = do
    atomically $ writeTVar eConnStatus newStatus
    makeRequest eConn updateStatus
  where
    updateStatus url = withResponse (statusRequest url) eConnManager $ \_ ->
        return ()
    statusRequest url = (parseUrlWithAdded url $ eConnAppPath eConn ++ "/status") {
          method = methodPut
        , queryString = encodeUtf8 . T.pack $ "value=" ++ toNetworkName newStatus
        }

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

registerInstance :: EurekaConnection -> IO ()
registerInstance eConn@EurekaConnection { eConnManager,
        eConnInstanceConfig = InstanceConfig {instanceAppName}
    } = do
    instanceInfo <- readEConnInstanceInfo eConn
    makeRequest eConn (sendRegister instanceInfo)
  where
    sendRegister instanceInfo url =
        withResponse (registerRequest url instanceInfo) eConnManager $ \_ ->
            return ()
    registerRequest url instanceInfo =
        (parseUrlWithAdded url $ "apps/" ++ instanceAppName) {
          method = methodPost
        , requestHeaders = [("Content-Type", "application/json")]
        , requestBody = RequestBodyLBS $ encode $ object [
            "instance" .= instanceInfo
            ]
        }


-- | Read the instance's status and use it to produce an InstanceInfo.
readEConnInstanceInfo :: EurekaConnection -> IO InstanceInfo
readEConnInstanceInfo eConn = eConnInstanceInfo eConn <$> readStatus eConn

-- | A helper function to read the instance's status.
readStatus :: EurekaConnection -> IO InstanceStatus
readStatus EurekaConnection { eConnStatus } = atomically (readTVar eConnStatus)

-- | Build an InstanceInfo describing this instance using information in a
-- EurekaConnection and the given status.  Reading status is impure, but this
-- function can do the bulk of the pure work.
eConnInstanceInfo :: EurekaConnection -> InstanceStatus -> InstanceInfo
eConnInstanceInfo eConn@EurekaConnection {
      eConnDataCenterInfo
    , eConnInstanceConfig = InstanceConfig {
          instanceAppName
        , instanceNonSecurePort
        , instanceSecurePort
        , instanceMetadata
        }
    , eConnHostname
    } status = InstanceInfo {
      instanceInfoHostName = eConnHostname
    , instanceInfoAppName = instanceAppName
    , instanceInfoIpAddr = eConnPublicIpv4 eConn
    , instanceInfoVipAddr = eConnVirtualHostname eConn
    , instanceInfoSecureVipAddr = eConnSecureVirtualHostname eConn
    , instanceInfoStatus = status
    , instanceInfoPort = instanceNonSecurePort
    , instanceInfoSecurePort = instanceSecurePort
    , instanceInfoDataCenterInfo = eConnDataCenterInfo
    , instanceInfoMetadata = instanceMetadata
    , instanceInfoIsCoordinatingDiscoveryServer = False
    }

-- | Get the virtual hostname from the Eureka connection, taking the real
-- hostname and instance configuration into account.
eConnVirtualHostname :: EurekaConnection -> String
eConnVirtualHostname eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig {
            instanceNonSecurePort,
            instanceVirtualHostname } } =
    fromMaybe
      (eConnPublicHostname eConn ++ ":" ++ show instanceNonSecurePort)
      instanceVirtualHostname

eConnSecureVirtualHostname :: EurekaConnection -> String
eConnSecureVirtualHostname eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig {
            instanceSecurePort,
            instanceSecureVirtualHostname } } =
    fromMaybe
      (eConnPublicHostname eConn ++ ":" ++ show instanceSecurePort)
      instanceSecureVirtualHostname

-- | Return the best hostname available.
eConnPublicHostname :: EurekaConnection -> String
eConnPublicHostname EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon {
            amazonPublicHostname } } = amazonPublicHostname
eConnPublicHostname EurekaConnection { eConnHostname } = eConnHostname

-- | Return the best IP address available.
eConnPublicIpv4 :: EurekaConnection -> String
eConnPublicIpv4 EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon {
            amazonPublicIpv4 } } = amazonPublicIpv4
eConnPublicIpv4 EurekaConnection { eConnHostIpv4 } = eConnHostIpv4

-- | Add an additional path fragment to a base URL.
--
-- I tried doing this using the http-types library but it was just so
-- inconvenient that I fell back to doing it this way. Alternative
-- implementations welcomed.
addPath :: String -> String -> String
addPath base additional = baseWithSlash ++ additional
  where
    baseWithSlash = if last base == '/' then base else base ++ "/"

disconnectEureka :: EurekaConnection -> IO ()
disconnectEureka eConn@EurekaConnection {
    eConnHeartbeatThread, eConnInstanceInfoReplicatorThread
    } = do
    killThread eConnHeartbeatThread
    killThread eConnInstanceInfoReplicatorThread
    setStatus eConn Down
    unregister eConn


unregister :: EurekaConnection -> IO ()
unregister eConn@EurekaConnection { eConnManager } = do
    -- N.B. This also catches all exceptions (see above), which the Java version
    -- does, presumably because unregistering could be something that happens as
    -- the instance crashes, and we don't want to mask the legitimate failure
    -- with some other frivolous failure that comes out of our failure to
    -- deregister.
    result <- try reallyUnregister
    case result of
        Right _ -> return ()
        Left err -> let errMsg = show (err :: SomeException) in
            errorM "Eureka.unregister" $
            appPath ++ " - de-registration failed " ++ errMsg
  where
    reallyUnregister = do
        responseStatus <- makeRequest eConn sendUnregister
        -- the two spaces between "deregister" and "status" are copied from the
        -- Java implementation
        infoM "Eureka.unregister" $
                appPath ++ " - deregister  status: " ++ show responseStatus
    appPath = eConnAppPath eConn
    sendUnregister url = withResponse (unregisterRequest url) eConnManager $
                        \resp -> return $ responseStatus resp
    unregisterRequest url = (parseUrlWithAppPath url eConn) {
          method = methodDelete
          }


type HeartbeatState = ()

postHeartbeat :: EurekaConnection -> HeartbeatState -> IO HeartbeatState
postHeartbeat eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig { instanceAppName },
    eConnManager
    } () = do
    -- N.B. This is more-or-less what's described by the Control.Exception
    -- documentation under "Catching all exceptions". We use try instead of
    -- catch because we aren't interested in asynchronous exceptions, so
    -- hopefully this won't accidentally catch too many exceptions.
    result <- try reallyPostHeartbeat
    case result of
        Right _ -> return ()
        Left err -> let errMsg = show (err :: SomeException) in
            errorM "Eureka.postHeartbeat" $
            appPath ++ " - was unable to send heartbeat! " ++ errMsg
  where
    reallyPostHeartbeat = do
        responseStatus <- makeRequest eConn sendHeartbeat
        debugM "Eureka.postHeartbeat" $
            appPath ++ " - Heartbeat status: " ++ show responseStatus
        when (responseStatus == status404) $ do
            infoM "Eureka.postHeartbeat" $
                appPath ++ " - Re-registering apps/" ++ instanceAppName
            registerInstance eConn
    appPath = eConnAppPath eConn
    sendHeartbeat url = withResponse (heartbeatRequest url) eConnManager $
                        \resp -> return $ responseStatus resp
    heartbeatRequest url = (parseUrlWithAppPath url eConn) {
          method = methodPut,
          checkStatus = \_ _ _ -> Nothing   -- so we can reregister if we get a 404
          }

-- | "IIR" stands for "instance info replicator", which is this thread's name
data IIRState = IIRState {
      iirLastAMIId :: Maybe String
      -- ^ The AMI ID of the coordinating server the last time we saw it.
      -- 'Nothing' on our first run.
    } deriving Show

instance Default IIRState where
    def = IIRState {
        iirLastAMIId = Nothing
        }

updateInstanceInfo :: EurekaConnection -> IIRState -> IO IIRState
updateInstanceInfo eConn oldState@IIRState { iirLastAMIId } = do
    eurekaServer <- getCoordinatingServer
    maybe (return oldState) updateDiscoveryServer eurekaServer
  where
    getCoordinatingServer :: IO (Maybe InstanceInfo)
    getCoordinatingServer = do
        -- N.B. The Java client does an in-memory lookup in a prepopulated hash
        -- rather than issuing the query itself. Failure there means getting a
        -- 'null' response. Here we can hit a 404 and die. Let's just replicate
        -- the silent failure of the Java version.
        eInstances <- try (lookupByAppName eConn discoveryAppId)
                      :: IO (Either HttpException [InstanceInfo])
        return $ case eInstances of
            Left _ -> Nothing
            Right instances -> find coordinator instances

    coordinator = instanceInfoIsCoordinatingDiscoveryServer
    updateDiscoveryServer :: InstanceInfo -> IO IIRState
    updateDiscoveryServer eurekaServer = do
        let mnewAMI = maybeGetAMIId eurekaServer
        maybe
            (return oldState { iirLastAMIId = mnewAMI })
            (checkDiscoveryServerChanged mnewAMI) iirLastAMIId

    checkDiscoveryServerChanged :: Maybe String -> String -> IO IIRState
    checkDiscoveryServerChanged mnewAMI lastAMI =
        if isNothing mnewAMI || mnewAMI == Just lastAMI
            then return oldState
            else do
            infoM "Eureka.updateInstanceInfo" $ "The eureka AMI ID changed from "
                ++ lastAMI ++ " to " ++ fromJust mnewAMI
                ++ ". Pushing the appinfo to eureka"

            status <- readStatus eConn
            -- N.B. The original client does this whenever the instance info is
            -- "dirty" -- its status or its metadata were updated. Additionally,
            -- its status can change as a result of a health check (in this
            -- thread).
            --
            -- We push status changes to Eureka immediately, so we don't do that
            -- here. We don't support mutable metadata yet either. Finally, we
            -- don't support health checks. In other words, this log message is
            -- a little redundant.
            infoM "Eureka.updateInstanceInfo" $ eConnAppPath eConn
                ++ " - retransmit instance info with status "
                ++ show status
            registerInstance eConn
            return oldState { iirLastAMIId = mnewAMI }

    maybeGetAMIId :: InstanceInfo -> Maybe String
    maybeGetAMIId InstanceInfo { instanceInfoDataCenterInfo = DataCenterAmazon {
        amazonAmiId
        }} = Just amazonAmiId
    maybeGetAMIId _ = Nothing
    -- FIXME: this is copied straight out of the Eureka source code, but there's
    -- no server on my network called DISCOVERY, so I don't know how it works.
    discoveryAppId = "DISCOVERY"

connectEureka :: Manager
              -> EurekaConfig -> InstanceConfig -> DataCenterInfo
              -> IO EurekaConnection
connectEureka manager
    eConfig@EurekaConfig{
        eurekaInstanceInfoReplicationInterval=instanceInfoInterval
        }
    iConfig@InstanceConfig{
        instanceLeaseRenewalInterval=heartbeatInterval
        , instanceEnabledOnInit
        } dataCenterInfo = mfix $ \econn -> do
    heartbeatThreadId <- forkIO $ heartbeatThread econn ()
    instanceInfoThreadId <- forkIO $ instanceInfoThread econn def
    statusVar <- atomically $ newTVar (if instanceEnabledOnInit then Up else Starting)

    hostname <- getHostName
    hostResolved <- getAddrInfo (Just myHints) (Just hostname) Nothing
    (Just hostIpv4, _) <- getNameInfo [NI_NUMERICHOST] True False
                          . addrAddress . head $ hostResolved
    return EurekaConnection {
          eConnEurekaConfig = eConfig
        , eConnInstanceConfig = iConfig
        , eConnHeartbeatThread = heartbeatThreadId
        , eConnInstanceInfoReplicatorThread = instanceInfoThreadId
        , eConnManager = manager
        , eConnDataCenterInfo = dataCenterInfo
        , eConnHostname = hostname
        , eConnHostIpv4 = hostIpv4
        , eConnStatus = statusVar
        }
  where
    heartbeatThread :: EurekaConnection -> () -> IO ()
    heartbeatThread = repeating heartbeatInterval . postHeartbeat
    instanceInfoThread = repeating instanceInfoInterval . updateInstanceInfo
    myHints = defaultHints { addrFamily = AF_INET }

-- | Make a request of each of the available servers. In case a server fails,
-- try consecutive servers until one works (or we run out of servers). If all
-- servers fail, throw the last exception we got.
makeRequest :: EurekaConnection -> (String -> IO a) -> IO a
makeRequest conn@EurekaConnection {eConnEurekaConfig}
    action = do
    result <- foldM tryNext (Left HandshakeFailed) urls
    case result of
        Left bad -> throw bad
        Right good -> return good
  where
    urls = eurekaUrlsByProximity eConnEurekaConfig (availabilityZone conn)
    (Left _) `tryNext` nextUrl = try (action nextUrl)
    (Right good) `tryNext` _ = return (Right good)

availabilityZonesFromConfig :: EurekaConfig -> [AvailabilityZone]
availabilityZonesFromConfig EurekaConfig{eurekaAvailabilityZones, eurekaRegion} =
    fromMaybe
        -- If we don't have any listed for this region, there's always the
        -- "default" availability zone.
        ["default"]
        (Map.lookup eurekaRegion eurekaAvailabilityZones)

eurekaServerServiceUrlsForZone :: EurekaConfig -> AvailabilityZone -> [String]
eurekaServerServiceUrlsForZone EurekaConfig {eurekaServerServiceUrls} zone =
    fromMaybe
        (error $ "couldn't find any Eureka server URLs for zone " ++ show zone
          ++ " in service config " ++ show eurekaServerServiceUrls)
        (Map.lookup zone eurekaServerServiceUrls)

availabilityZone :: EurekaConnection -> AvailabilityZone
availabilityZone EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon {amazonAvailabilityZone}
    } = amazonAvailabilityZone
availabilityZone EurekaConnection {eConnEurekaConfig} =
    head $ availabilityZonesFromConfig eConnEurekaConfig ++ ["default"]

eConnAppPath :: EurekaConnection -> String
eConnAppPath eConn@EurekaConnection {
    eConnInstanceConfig = InstanceConfig {instanceAppName}
    } =
    "apps/" ++ instanceAppName ++ "/" ++ eConnInstanceId eConn

-- | Produce an ID to use when identifying this instance.  If running in a
-- datacenter, this gets the ID of the machine.  Otherwise, falls back to the
-- hostname.
eConnInstanceId :: EurekaConnection -> String
eConnInstanceId EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon { amazonInstanceId }
    } = amazonInstanceId
eConnInstanceId EurekaConnection { eConnHostname } = eConnHostname

parseUrlWithAdded :: String -> String -> Request
parseUrlWithAdded url = fromJust . parseUrl . addPath url

parseUrlWithAppPath :: String -> EurekaConnection -> Request
parseUrlWithAppPath url = parseUrlWithAdded url . eConnAppPath

requestJSON :: Request -> Request
requestJSON r = r {
    requestHeaders = ("Accept", encodeUtf8 "application/json") : requestHeaders r
    }

-- | Perform an action every 'delay' seconds.
-- This action keeps track of its internal state using 'a'.
-- Delays are not exact; we use threadDelay to schedule the repetition.
repeating :: Int -> (a -> IO a) -> a -> IO ()
repeating i f = loop
  where
    loop a0 = do
        result <- f a0
        threadDelay (i * 1000 * 1000)
        loop result

-- | Generate a list of rotations of a list.
-- > rotations [1..4]
-- [[1,2,3,4],[2,3,4,1],[3,4,1,2],[4,1,2,3]]
rotations :: [a] -> [[a]]
rotations lst = map (take (length lst) . flip drop (cycle lst)) [0..length lst - 1]
