module WeiXin.PublicPlatform.BgWork where

import ClassyPrelude hiding (catch)
import Control.Monad.Catch                  ( catch )
import Data.Acid
import Data.Time                            (addUTCTime, NominalDiffTime)
import Control.Monad.Logger
import System.Timeout                       (timeout)
import Control.Exception                    (evaluate)

import WeiXin.PublicPlatform.Acid
import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.Types
import WeiXin.PublicPlatform.Security


-- | 检查最新的 access token 是否已接近过期
-- 如是，则向服务器请求更新
refreshAccessTokenIfNeeded ::
    (MonadIO m, MonadLogger m, MonadCatch m) =>
    WxppAppConfig
    -> AcidState WxppAcidState
    -> NominalDiffTime
    -> m ()
refreshAccessTokenIfNeeded wac acid dt = do
    now <- liftIO getCurrentTime
    let t = addUTCTime (negate $ abs dt) now
    expired <- liftM (fromMaybe True . fmap ((<= t) . snd)) $
                        liftIO $ query acid $ WxppAcidGetAcccessToken
    when (expired) $ do
        ws_res <- tryWxppWsResult $ refreshAccessToken wac
        case ws_res of
            Left err -> do
                $(logErrorS) wxppLogSource $
                    "Failed to refresh access token: "
                        <> fromString (show err)
            Right (AccessTokenResp atk ttl) -> do
                $(logDebugS) wxppLogSource $ fromString $
                    "New access token acquired, expired in: " <> show ttl
                now' <- liftIO getCurrentTime
                let expiry = addUTCTime (fromIntegral ttl) now'
                liftIO $ update acid $ WxppAcidAddAcccessToken atk expiry
                liftIO $ update acid $ WxppAcidPurgeAcccessToken now'


-- | infinite loop to refresh access token
-- Create a backgroup thread to call this, so that access token can be keep fresh.
loopRefreshAccessToken ::
    (MonadIO m, MonadLogger m, MonadCatch m) =>
    IO Bool     -- ^ This function should be a blocking op,
                -- return True if the infinite should be aborted.
    -> Int      -- ^ interval between successive checking (in seconds)
    -> WxppAppConfig
    -> AcidState WxppAcidState
    -> NominalDiffTime
    -> m ()
loopRefreshAccessToken chk_abort intv wac acid dt = do
    loopRunBgJob chk_abort intv $ refreshAccessTokenIfNeeded wac acid dt


loopRunBgJob :: (MonadIO m, MonadCatch m) =>
    IO Bool     -- ^ This function should be a blocking op,
                -- return True if the infinite should be aborted immediately.
    -> Int      -- ^ interval in seconds
    -> m ()     -- ^ the job to be repeatly called
    -> m ()
loopRunBgJob chk_abort intv job = loop
    where
        loop = do
            job >>= liftIO . evaluate
            m_if_abort <- liftIO $ timeout (intv * 1000 * 1000) chk_abort
            case m_if_abort of
                Just True   -> return ()
                _           -> loop


-- | 重复执行计算，并记录出现的异常
runRepeatlyLogExc ::
    (MonadIO m, MonadLogger m, MonadCatch m) =>
    MVar a
    -> Int      -- ^ ms
    -> m () -> m ()
runRepeatlyLogExc exit_mvar interval f = go
    where
        go = do
            f `catch` h
            liftIO (timeout interval $ readMVar exit_mvar)
                >>= maybe go (const $ return ())
        h e = do
            $(logErrorS) wxppLogSource $
                "Got exception in loop: "
                    <> fromString (show (e :: SomeException))
