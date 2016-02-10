{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Network.Eureka.Connection (
    EurekaConnection(..)
  , connectEureka
  , disconnectEureka
  , withEureka
  , withEurekaH
  , registerInstance
  , unregister
  , updateInstanceInfo
  , setStatus
  ) where

import           Control.Concurrent        (forkIO, killThread,
                                            threadDelay)
import           Control.Concurrent.STM    (atomically, newTVar, readTVar,
                                            writeTVar)
import           Control.Exception         (SomeException, try, Exception,
                                            bracket)
import           Control.Monad             (when, liftM)
import           Control.Monad.Fix         (mfix)
import           Control.Monad.IO.Class    (liftIO)
import           Control.Monad.Logger      (logInfo, logError, logDebug,
                                            MonadLoggerIO, askLoggerIO,
                                            runLoggingT, LoggingT)
import           Data.Aeson                (encode, object, (.=))
import           Data.Default              (def)
import           Data.Functor              (void)
import           Data.List                 (find)
import           Data.Maybe                (fromJust, fromMaybe, isNothing)
import qualified Data.Text                 as T
import           Data.Text.Encoding        (encodeUtf8)
import           Network.BSD               (getHostName)
import           Network.HTTP.Client       (HttpException, Manager,
                                            Request (checkStatus, method,
                                            requestBody, requestHeaders),
                                            RequestBody (RequestBodyLBS),
                                            defaultManagerSettings,
                                            newManager, queryString,
                                            responseStatus, withResponse)
import           Network.HTTP.Types.Method (methodDelete, methodPost, methodPut)
import           Network.HTTP.Types.Status (status404)
import           Network.Socket            (AddrInfo (addrAddress, addrFamily),
                                            Family (AF_INET),
                                            NameInfoFlag (NI_NUMERICHOST),
                                            defaultHints, getAddrInfo,
                                            getNameInfo)
import           System.Posix.Signals      (Handler (Catch),
                                            installHandler,
                                            sigTERM, sigINT,
                                            raiseSignal)


import           Network.Eureka.Types      (EurekaConnection(..),
                                            AmazonDataCenterInfo (..),
                                            DataCenterInfo (..),
                                            EurekaConfig (..),
                                            InstanceConfig (..),
                                            InstanceInfo (..),
                                            InstanceStatus (..),
                                            IIRState(..),
                                            toNetworkName)

import Network.Eureka.Request (makeRequest)
import Network.Eureka.Util (parseUrlWithAdded)
import Network.Eureka.Application (lookupByAppName)


type HeartbeatState = ()

connectEureka :: (MonadLoggerIO io)
              => Manager
              -> EurekaConfig -> InstanceConfig -> DataCenterInfo
              -> io EurekaConnection
connectEureka manager
    eConfig@EurekaConfig{
        eurekaInstanceInfoReplicationInterval=instanceInfoInterval
        }
    iConfig@InstanceConfig{
        instanceLeaseRenewalInterval=heartbeatInterval
        , instanceEnabledOnInit
        , instanceHostName
        } dataCenterInfo
  = do
    logging <- askLoggerIO
    liftIO . mfix $ \econn -> (`runLoggingT` logging) $ do
      heartbeatThreadId <- forkL $ heartbeatThread econn ()
      instanceInfoThreadId <- forkL $ instanceInfoThread econn def
      statusVar <- liftIO . atomically $ newTVar (if instanceEnabledOnInit then Up else Starting)

      hostname <-liftIO $  maybe getHostName return instanceHostName
      hostResolved <- liftIO $ getAddrInfo (Just myHints) (Just hostname) Nothing
      (Just hostIpv4, _) <-
        liftIO
        . getNameInfo [NI_NUMERICHOST] True False
        . addrAddress
        . head
        $ hostResolved
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
    heartbeatThread :: (MonadLoggerIO io) => EurekaConnection -> () -> io ()
    heartbeatThread = repeating heartbeatInterval . postHeartbeat
    instanceInfoThread = repeating instanceInfoInterval . updateInstanceInfo
    myHints = defaultHints { addrFamily = AF_INET }
    forkL io = liftIO . forkIO . runLoggingT io =<< askLoggerIO

    -- | Perform an action every 'delay' seconds.
    -- This action keeps track of its internal state using 'a'.
    -- Delays are not exact; we use threadDelay to schedule the repetition.
    repeating :: (MonadLoggerIO io) => Int -> (a -> io a) -> a -> io ()
    repeating i f = loop
      where
        loop a0 = do
            result <- f a0
            liftIO $ threadDelay (i * 1000 * 1000)
            loop result

    postHeartbeat :: (MonadLoggerIO io)
      => EurekaConnection
      -> HeartbeatState
      -> io HeartbeatState
    postHeartbeat eConn@EurekaConnection {
        eConnInstanceConfig = InstanceConfig { instanceAppName },
        eConnManager
        } () = do
        -- N.B. This is more-or-less what's described by the Control.Exception
        -- documentation under "Catching all exceptions". We use try instead of
        -- catch because we aren't interested in asynchronous exceptions, so
        -- hopefully this won't accidentally catch too many exceptions.
        result <- tryL reallyPostHeartbeat
        case result of
            Right _ -> return ()
            Left err -> let errMsg = show (err :: SomeException) in
                $(logError) . T.pack
                    $ appPath ++ " - was unable to send heartbeat! " ++ errMsg
      where
        reallyPostHeartbeat = do
            responseStatus <- makeRequest eConn sendHeartbeat
            $(logDebug) . T.pack
                $ appPath ++ " - Heartbeat status: " ++ show responseStatus
            when (responseStatus == status404) $ do
                $(logInfo) . T.pack
                    $ appPath ++ " - Re-registering apps/" ++ instanceAppName
                registerInstance eConn
        appPath = eConnAppPath eConn
        sendHeartbeat url = withResponse (heartbeatRequest url) eConnManager $
                            \resp -> return $ responseStatus resp
        heartbeatRequest url = (parseUrlWithAppPath url eConn) {
              method = methodPut,
              checkStatus = \_ _ _ -> Nothing   -- so we can reregister if we get a 404
              }

-- | Run an action inside of an Eureka context.
-- This function registers the currently running instance with Eureka,
-- it then passes the Eureka information into the action.
-- After the action is completed (or crashes), deregister from Eureka.
withEurekaH :: (MonadLoggerIO io)
            => Bool
            -- ^ Whether to switch sigTERM into sigINT. If this is not done, the user
            -- must handle Eureka's resource cleaning in the case of sigTERM since ghc
            -- doesn't raise an exception for sigTERM. See:
            -- <https://ghc.haskell.org/trac/ghc/ticket/6113#comment:1>
            -> EurekaConfig
            -- ^ The Eureka configuration
            -> InstanceConfig
            -- ^ The instance configuration
            -> DataCenterInfo
            -> (EurekaConnection -> IO a)
            -- ^ The action that will run inside the Eureka context.
            -> io a
withEurekaH useTermHandle eConfig iConfig iInfo m = do
    manager <- liftIO $ newManager defaultManagerSettings
    liftIO $ when useTermHandle . void $ installHandler sigTERM (Catch $ raiseSignal sigINT) Nothing
    logging <- askLoggerIO
    liftIO $ bracket
      (flip runLoggingT logging $ connectEureka manager eConfig iConfig iInfo)
      (flip runLoggingT logging . disconnectEureka)
      (flip runLoggingT logging . registerAndRun)
  where
    registerAndRun eConn = do
        registerInstance eConn
        liftIO $ m eConn

-- | Like 'withEurekaH' but overloaded to convert sigTERM into sigINT
withEureka :: (MonadLoggerIO io)
  => EurekaConfig
  -> InstanceConfig
  -> DataCenterInfo
  -> (EurekaConnection -> IO a)
  -> io a
withEureka = withEurekaH True

registerInstance :: (MonadLoggerIO io) => EurekaConnection -> io ()
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
    readEConnInstanceInfo :: (MonadLoggerIO io)
      => EurekaConnection
      -> io InstanceInfo
    readEConnInstanceInfo conn = eConnInstanceInfo conn `liftM` readStatus conn

-- | A helper function to read the instance's status.
readStatus :: (MonadLoggerIO io)
  => EurekaConnection
  -> io InstanceStatus
readStatus EurekaConnection { eConnStatus } =
  liftIO $ atomically (readTVar eConnStatus)

unregister :: (MonadLoggerIO io) => EurekaConnection -> io ()
unregister eConn@EurekaConnection { eConnManager } = do
  -- N.B. This also catches all exceptions (see above), which the Java version
  -- does, presumably because unregistering could be something that happens as
  -- the instance crashes, and we don't want to mask the legitimate failure
  -- with some other frivolous failure that comes out of our failure to
  -- deregister.
  result <- tryL reallyUnregister
  case result of
      Right _ -> return ()
      Left err -> let errMsg = show (err :: SomeException) in
          $(logError) . T.pack
              $ appPath ++ " - de-registration failed " ++ errMsg
  where
    reallyUnregister = do
        responseStatus <- makeRequest eConn sendUnregister
        -- the two spaces between "deregister" and "status" are copied from the
        -- Java implementation
        $(logInfo) . T.pack
            $ appPath ++ " - deregister  status: " ++ show responseStatus
    appPath = eConnAppPath eConn
    sendUnregister url = withResponse (unregisterRequest url) eConnManager $
                        \resp -> return $ responseStatus resp
    unregisterRequest url = (parseUrlWithAppPath url eConn) {
          method = methodDelete
          }


updateInstanceInfo :: (MonadLoggerIO io)
  => EurekaConnection
  -> IIRState
  -> io IIRState
updateInstanceInfo eConn oldState@IIRState { iirLastAMIId } = do
  eurekaServer <- getCoordinatingServer
  maybe (return oldState) updateDiscoveryServer eurekaServer
  where
    getCoordinatingServer :: (MonadLoggerIO io) => io (Maybe InstanceInfo)
    getCoordinatingServer = do
        -- N.B. The Java client does an in-memory lookup in a prepopulated hash
        -- rather than issuing the query itself. Failure there means getting a
        -- 'null' response. Here we can hit a 404 and die. Let's just replicate
        -- the silent failure of the Java version.
        eInstances <- tryL (lookupByAppName eConn discoveryAppId)
        return $ case eInstances :: Either HttpException [InstanceInfo] of
            Left _ -> Nothing
            Right instances -> find coordinator instances

    coordinator = instanceInfoIsCoordinatingDiscoveryServer
    updateDiscoveryServer :: (MonadLoggerIO io) => InstanceInfo -> io IIRState
    updateDiscoveryServer eurekaServer = do
        let mnewAMI = maybeGetAMIId eurekaServer
        maybe
            (return oldState { iirLastAMIId = mnewAMI })
            (checkDiscoveryServerChanged mnewAMI) iirLastAMIId

    checkDiscoveryServerChanged :: (MonadLoggerIO io)
        => Maybe String
        -> String
        -> io IIRState
    checkDiscoveryServerChanged mnewAMI lastAMI =
        if isNothing mnewAMI || mnewAMI == Just lastAMI
            then return oldState
            else do
            $(logInfo) . T.pack
                $ "The eureka AMI ID changed from "
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
            $(logInfo) . T.pack
                $ eConnAppPath eConn
                ++ " - retransmit instance info with status "
                ++ show status
            registerInstance eConn
            return oldState { iirLastAMIId = mnewAMI }

    maybeGetAMIId :: InstanceInfo -> Maybe String
    maybeGetAMIId InstanceInfo {
        instanceInfoDataCenterInfo =
          DataCenterAmazon AmazonDataCenterInfo { amazonAmiId }
      } = Just amazonAmiId
    maybeGetAMIId _ = Nothing
    -- FIXME: this is copied straight out of the Eureka source code, but there's
    -- no server on my network called DISCOVERY, so I don't know how it works.
    discoveryAppId = "DISCOVERY"


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
    } status = InstanceInfo {
      instanceInfoHostName = eConnPublicHostname eConn
    , instanceInfoAppName = instanceAppName
    , instanceInfoIpAddr = eConnPublicIpv4 eConn
    , instanceInfoVipAddr = eConnVirtualHostname eConn
    , instanceInfoSecureVipAddr = eConnSecureVirtualHostname eConn
    , instanceInfoStatus = status
    , instanceInfoPort = instanceNonSecurePort
    , instanceInfoSecurePort = instanceSecurePort
    , instanceInfoHomePageUrl = Just $ eConnHomePageUrl eConn
    , instanceInfoStatusPageUrl = Just $ eConnStatusPageUrl eConn
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
    eConnDataCenterInfo = DataCenterAmazon AmazonDataCenterInfo {
            amazonPublicHostname } } = amazonPublicHostname
eConnPublicHostname EurekaConnection { eConnHostname } = eConnHostname

-- | Return the best IP address available.
eConnPublicIpv4 :: EurekaConnection -> String
eConnPublicIpv4 EurekaConnection {
    eConnDataCenterInfo = DataCenterAmazon AmazonDataCenterInfo {
            amazonPublicIpv4 } } = amazonPublicIpv4
eConnPublicIpv4 EurekaConnection { eConnHostIpv4 } = eConnHostIpv4

-- | Return instance's status page URL.
--
-- The full URL should follow the format @http://${eureka.hostname}:8080/@ where
-- the value @${eureka.hostname}@ is replaced at runtime with instance's public
-- hostname.
eConnStatusPageUrl :: EurekaConnection -> String
eConnStatusPageUrl eConn@EurekaConnection {
      eConnInstanceConfig = InstanceConfig { instanceStatusPageUrl }
    } =
  interpolateInstanceUrl eConn (fromMaybe "" instanceStatusPageUrl)

-- | Return instance's home page URL.
--
-- The full URL should follow the format @http://${eureka.hostname}:8080/@ where
-- the value @${eureka.hostname}@ is replaced at runtime with instance's public
-- hostname.
eConnHomePageUrl :: EurekaConnection -> String
eConnHomePageUrl eConn@EurekaConnection {
      eConnInstanceConfig = InstanceConfig { instanceHomePageUrl }
    } =
  interpolateInstanceUrl eConn instanceHomePageUrl

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
    eConnDataCenterInfo =
      DataCenterAmazon AmazonDataCenterInfo { amazonInstanceId }
  } = amazonInstanceId
eConnInstanceId EurekaConnection { eConnHostname } = eConnHostname

parseUrlWithAppPath :: String -> EurekaConnection -> Request
parseUrlWithAppPath url = parseUrlWithAdded url . eConnAppPath


-- | Interpolate instance URL.
--
-- Given a URL that follows the format @http://${eureka.hostname}:8080/@, it
-- replaces the value @${eureka.hostname}@ with instance's public hostname.
interpolateInstanceUrl :: EurekaConnection -> String -> String
interpolateInstanceUrl eConn instanceUrl =
  T.unpack $ T.replace
    (T.pack "${eureka.hostname}")
    (T.pack (eConnPublicHostname eConn))
    (T.pack instanceUrl)

disconnectEureka :: (MonadLoggerIO io) => EurekaConnection -> io ()
disconnectEureka eConn@EurekaConnection {
    eConnHeartbeatThread, eConnInstanceInfoReplicatorThread
    } = do
    liftIO $ killThread eConnHeartbeatThread
    liftIO $ killThread eConnInstanceInfoReplicatorThread
    setStatus eConn Down
    unregister eConn

setStatus :: (MonadLoggerIO io) => EurekaConnection -> InstanceStatus -> io ()
setStatus eConn@EurekaConnection { eConnManager, eConnStatus } newStatus = do
    liftIO . atomically $ writeTVar eConnStatus newStatus
    makeRequest eConn updateStatus
  where
    updateStatus url = withResponse (statusRequest url) eConnManager $ \_ ->
        return ()
    statusRequest url = (parseUrlWithAdded url $ eConnAppPath eConn ++ "/status") {
          method = methodPut
        , queryString = encodeUtf8 . T.pack $ "value=" ++ toNetworkName newStatus
        }

{- |
  A monadlogging version of try.
-}
tryL :: (MonadLoggerIO io, Exception e) => LoggingT IO a -> io (Either e a)
tryL io = liftIO . try . runLoggingT io =<< askLoggerIO


