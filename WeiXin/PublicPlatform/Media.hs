{-# LANGUAGE ScopedTypeVariables #-}
module WeiXin.PublicPlatform.Media
    ( module WeiXin.PublicPlatform.Media
    , module WeiXin.PublicPlatform.Class
    ) where

import ClassyPrelude hiding (catch)
import qualified Data.Text                  as T
import Network.Wreq
import Control.Lens
import Control.Monad.Logger
import Network.Mime                         (MimeType, defaultMimeLookup)
import qualified Data.ByteString.Lazy       as LB
import Control.Monad.Catch                  (catch, catches, Handler(..))
import Data.Yaml                            (ParseException)
import Data.List.NonEmpty                   as LNE
import Data.Aeson                           (FromJSON(..), withObject, (.:))
import Network.HTTP                         (urlEncodeVars)
import System.FilePath                      (takeFileName)

import WeiXin.PublicPlatform.Class
import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.Utils


-- | 生成直接下载临时素材的URL，可用于从第三方平台直接下载
-- CAUTION: URL 包含 access token 敏感信息，不要交给不可信的第三方
wxppDownloadMediaUrl :: Bool    -- ^ 文档说下载视频时不能用 https，但这个信息只有调用者才知道
                    -> AccessToken
                    -> WxppBriefMediaID
                    -> UrlText
wxppDownloadMediaUrl if_ssl (AccessToken { accessTokenData = atk }) mid =
    UrlText $ fromString $ url0 <> "?" <> qs
    where
        url0 = (if if_ssl then wxppRemoteApiBaseUrl else wxppRemoteApiBaseUrlNoSsl) <> "/media/get"
        vars =  [ ("access_token", T.unpack atk)
                , ("media_id", T.unpack (unWxppBriefMediaID mid))
                ]
        qs  = urlEncodeVars vars


-- | 下载一个多媒体文件
wxppDownloadMedia ::
    ( MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m) =>
    Bool    -- ^ 文档说下载视频时不能用 https，但这个信息只有调用者才知道
    -> AccessToken
    -> WxppBriefMediaID
    -> m (Response LB.ByteString)
wxppDownloadMedia if_ssl (AccessToken { accessTokenData = atk }) mid = do
    let url = (if if_ssl then wxppRemoteApiBaseUrl else wxppRemoteApiBaseUrlNoSsl) <> "/media/get"
        opts = defaults & param "access_token" .~ [ atk ]
                        & param "media_id" .~ [ unWxppBriefMediaID mid ]
    rb <- liftIO $ getWith opts url

    -- 需要某种方法区别正常和异常的返回
    -- 使用 Content-Type 的方式
    -- 但 content-type 的内容严格地说不是一个简单的字串比较就了事的
    -- rb ^. responseHeader "Content-Type"
    -- 这里使用的方法是先测试一下当作错误报告的 json 解释，不行就认为是正常返回
    let as_json = liftM (view responseBody) $ asJSON $ alterContentTypeToJson rb
        unexpected_jsn = \(_ :: ()) -> do
            -- 至此，说明报文真的是个json，而且不是错误报文
            $logErrorS wxppLogSource $ "cannot parse download media respnose."
            throwM $ userError "cannot parse download media respnose."

    (as_json >>= either throwM unexpected_jsn . unWxppWsResp)
                `catch`
                    (\(_ :: JSONError) -> return rb)


wxppUploadMediaInternal ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> WxppMediaType
    -> Part
    -> m UploadResult
wxppUploadMediaInternal (AccessToken { accessTokenData = atk }) mtype fpart = do
    let url = wxppRemoteApiBaseUrl <> "/media/upload"
        opts = defaults & param "access_token" .~ [ atk ]
                        & param "type" .~ [ wxppMediaTypeString mtype :: Text]
    (liftIO $ postWith opts url $ fpart & partName .~ "media")
        >>= asWxppWsResponseNormal'


-- | 上传本地一个文件
wxppUploadMedia ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> WxppMediaType
    -> FilePath
    -> m UploadResult
wxppUploadMedia atk mtype fp = do
    wxppUploadMediaInternal atk mtype $
        partFileSource "media" fp
            & partContentType .~ Just (defaultMimeLookup $ fromString $ takeFileName fp)

-- | 上传已在内存中的 ByteString
wxppUploadMediaBS ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> WxppMediaType
    -> MimeType
    -> String
    -> ByteString
    -> m UploadResult
wxppUploadMediaBS atk mtype mime filename bs = do
    wxppUploadMediaInternal atk mtype $
        partBS "media" bs & partFileName .~ Just filename
                            & partContentType .~ Just mime

wxppUploadMediaLBS ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> WxppMediaType
    -> MimeType
    -> String
    -> LB.ByteString
    -> m UploadResult
wxppUploadMediaLBS atk mtype mime filename bs = do
    wxppUploadMediaInternal atk mtype $
        partLBS "media" bs & partFileName .~ Just filename
                            & partContentType .~ Just mime

wxppUploadMediaCached ::
    ( MonadIO m, MonadLogger m, MonadThrow m, WxppCacheTokenReader c, WxppCacheTemp c) =>
    c
    -> AccessToken
    -> WxppMediaType
    -> FilePath
    -> m UploadResult
wxppUploadMediaCached cache atk mtype fp = do
    h <- liftIO $ sha256HashFile fp
    m_res <- liftIO $ wxppCacheLookupUploadedMediaIDByHash cache app_id h
    now <- liftIO getCurrentTime
    let m_res' = join $ flip fmap m_res $
                    \x -> if (usableUploadResult now dt x && urMediaType x == mtype)
                                then Just x
                                else Nothing
    case m_res' of
        Nothing -> do
            u_res <- wxppUploadMedia atk mtype fp
            liftIO $ wxppCacheSaveUploadedMediaID cache app_id h u_res
            return u_res

        Just x -> return x

    where
        dt = fromIntegral (60 * 60 * 24 :: Int)
        app_id = accessTokenApp atk


-- | 这里有个问题：如果之前上传过的文件的 mime 发生变化，可能会使用旧的文件 media id
wxppUploadMediaCachedBS ::
    ( MonadIO m, MonadLogger m, MonadThrow m, WxppCacheTokenReader c, WxppCacheTemp c) =>
    c
    -> AccessToken
    -> WxppMediaType
    -> MimeType
    -> String
    -> ByteString
    -> m UploadResult
wxppUploadMediaCachedBS cache atk mtype mime filename bs = do
    let h = sha256HashBS bs
    m_res <- liftIO $ wxppCacheLookupUploadedMediaIDByHash cache app_id h
    now <- liftIO getCurrentTime
    u_res <- maybe (wxppUploadMediaBS atk mtype mime filename bs) return $
        join $ flip fmap m_res $
                \x -> if (usableUploadResult now dt x && urMediaType x == mtype)
                            then Just x
                            else Nothing

    liftIO $ wxppCacheSaveUploadedMediaID cache app_id h u_res
    return u_res
    where
        dt = fromIntegral (60 * 60 * 24 :: Int)
        app_id = accessTokenApp atk


newtype UploadImgResult = UploadImgResult UrlText

instance FromJSON UploadImgResult where
    parseJSON = withObject "UploadImgResult" $ \o ->
                    UploadImgResult <$> o .: "url"

-- | 这是在群发文档中描述的特别接口，只用于上传图片，jpg/png格式
-- 不占用永久素材限额
-- 回复得到一个 URL，用于图文消息中
wxppUploadImageGetUrlInternal ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> Part
    -> m UrlText
wxppUploadImageGetUrlInternal (AccessToken { accessTokenData = atk }) fpart = do
    let url = wxppRemoteApiBaseUrl <> "/media/uploadimg"
        opts = defaults & param "access_token" .~ [ atk ]
    UploadImgResult media_url <- (liftIO $ postWith opts url $ fpart & partName .~ "media")
        >>= asWxppWsResponseNormal'
    return media_url

wxppUploadImageGetUrl ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> FilePath
    -> m UrlText
wxppUploadImageGetUrl atk fp = do
    wxppUploadImageGetUrlInternal atk $ partFileSource "media" fp

wxppUploadImageGetUrlBS ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken
    -> MimeType
    -> FilePath
    -> ByteString
    -> m UrlText
wxppUploadImageGetUrlBS atk mime filename bs = do
    wxppUploadImageGetUrlInternal atk $
        partBS "media" bs & partFileName .~ Just filename
                            & partContentType .~ Just mime


-- | 从 WxppOutMsgL 计算出 WxppOutMsg
-- 工作包括：
-- * 把 WxppOutMsgL 里的文件路径变换成 WxppBriefMediaID
-- * 执行必要的延迟加载
-- 这个函数会抛出异常 见 tryWxppWsResult
-- 下面还有个尽量不抛出异常的版本
fromWxppOutMsgL ::
    ( MonadIO m, MonadLogger m, MonadThrow m, WxppCacheTokenReader c, WxppCacheTemp c) =>
    NonEmpty FilePath
    -> c
    -> m AccessToken
    -> WxppOutMsgL
    -> m WxppOutMsg
fromWxppOutMsgL _       _   _   (WxppOutMsgTextL x)     = return (WxppOutMsgText x)

fromWxppOutMsgL msg_dir _   _   (WxppOutMsgNewsL loaders)  =
        liftM WxppOutMsgNews $ do
            sequence $ fmap (runDelayedYamlLoaderExcL msg_dir) loaders

fromWxppOutMsgL _ cache    get_atk (WxppOutMsgImageL fp)   = do
        atk <- get_atk
        liftM (WxppOutMsgImage . fromWxppBriefMediaID . urMediaId) $
            wxppUploadMediaCached cache atk WxppMediaTypeImage fp

fromWxppOutMsgL _ cache    get_atk (WxppOutMsgVoiceL fp)   = do
        atk <- get_atk
        liftM (WxppOutMsgVoice . fromWxppBriefMediaID . urMediaId) $
            wxppUploadMediaCached cache atk WxppMediaTypeVoice fp

fromWxppOutMsgL _ cache    get_atk (WxppOutMsgVideoL fp m_fp2 x1 x2)   = do
        atk <- get_atk
        liftM2 (\i i2 -> WxppOutMsgVideo i i2 x1 x2)
            (liftM (fromWxppBriefMediaID . urMediaId) $ wxppUploadMediaCached cache atk WxppMediaTypeVoice fp)
            (liftM (fmap $ fromWxppBriefMediaID . urMediaId) $
                mapM (wxppUploadMediaCached cache atk WxppMediaTypeVoice) m_fp2)

fromWxppOutMsgL _ cache    get_atk (WxppOutMsgMusicL fp x1 x2 x3 x4)   = do
        atk <- get_atk
        liftM ((\i -> WxppOutMsgMusic i x1 x2 x3 x4) . fromWxppBriefMediaID . urMediaId) $
            wxppUploadMediaCached cache atk WxppMediaTypeVoice fp

fromWxppOutMsgL _ _       _   WxppOutMsgTransferToCustomerServiceL =
                                                    return WxppOutMsgTransferToCustomerService


fromWxppOutMsgL' ::
    ( MonadIO m, MonadLogger m, MonadCatch m, WxppCacheTokenReader c, WxppCacheTemp c) =>
    NonEmpty FilePath
    -> c
    -> m AccessToken
    -> WxppOutMsgL
    -> m (Either String WxppOutMsg)
fromWxppOutMsgL' fp cache get_atk out_msg_l =
    (liftM Right $ fromWxppOutMsgL fp cache get_atk out_msg_l) `catches`
        (Handler h_yaml_exc : fmap unifyExcHandler wxppWsExcHandlers)
    where
        h_yaml_exc e = return $ Left $ show (e :: ParseException)
