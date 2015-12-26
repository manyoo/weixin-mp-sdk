{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}
module WeiXin.PublicPlatform.Yesod.Site
    ( module WeiXin.PublicPlatform.Yesod.Site
    , module WeiXin.PublicPlatform.Yesod.Site.Data
    ) where

import ClassyPrelude
import Yesod
import qualified Data.ByteString.Lazy       as LB
import qualified Data.ByteString.Base16     as B16
import qualified Data.ByteString.Base64.URL as B64L
import qualified Data.ByteString.Char8      as C8
import qualified Data.Text                  as T
import qualified Data.Set                   as Set
import Control.Monad.Trans.Except           (runExceptT, ExceptT(..), throwE)
import Control.Concurrent.Async             (async)
import Control.Concurrent                   (threadDelay, forkIO)
import Control.Monad.Trans.Maybe            (runMaybeT, MaybeT(..))
import Network.URI                          ( parseURI, uriQuery, uriToString )
import Network.HTTP                         ( urlEncode )
import Yesod.Default.Util                   ( widgetFileReload )
import Data.Time                            ( addUTCTime )

import Yesod.Helpers.Handler                ( httpErrorWhenParamError
                                            , reqGetParamE'
                                            , paramErrorFromEither
                                            , httpErrorRetryWithValidParams
                                            , reqPathPieceParamPostGet
                                            , getCurrentUrl
                                            )
import Yesod.Helpers.Logger
import Control.Monad.Logger

import Network.Wai                          (lazyRequestBody)
import Text.XML                             (renderText, parseLBS)
import Data.Default                         (def)
import qualified Data.Text.Lazy             as LT
import Yesod.Core.Types                     (HandlerContents(HCError))
import Data.Yaml                            (decodeEither')
import Network.HTTP.Types.Status            (mkStatus)
import Data.Conduit
import Data.Conduit.Binary                  (sinkLbs)
import qualified Data.Conduit.List          as CL
import qualified Data.Conduit.Combinators   as CC
import qualified Data.Aeson                 as A

import Database.Persist.Sql

import WeiXin.PublicPlatform.Yesod.Types    (handlerGetWeixinClientVersion)
import WeiXin.PublicPlatform.Yesod.Model
import WeiXin.PublicPlatform.Yesod.Site.Data
import WeiXin.PublicPlatform.Class
import WeiXin.PublicPlatform.Security
import WeiXin.PublicPlatform.Message
import WeiXin.PublicPlatform.Error
import WeiXin.PublicPlatform.WS
import WeiXin.PublicPlatform.EndUser
import WeiXin.PublicPlatform.QRCode
import WeiXin.PublicPlatform.OAuth
import WeiXin.PublicPlatform.Utils


withWxppSubHandler :: ( MonadHandler m, HandlerSite m ~ MaybeWxppSub
                    , MonadBaseControl IO m
                    )
                    => (WxppSub -> m a)
                    -> m a
withWxppSubHandler f = do
    getYesod
        >>= liftIO . unMaybeWxppSub
        >>= maybe notFound return
        >>= f

checkSignature' :: Yesod master =>
    WxppSub -> HandlerT MaybeWxppSub (HandlerT master IO) ()
checkSignature' foundation = do

    let token = wxppConfigAppToken $ wxppSubAppConfig $ foundation

        check_sign (tt, nn, sign) =
            if B16.encode sign0 == encodeUtf8 ( T.toLower sign )
                then Right ()
                else Left $ "invalid signature"
            where
                sign0 = wxppSignature token tt nn ""

    (httpErrorWhenParamError =<<) $ do
        -- check required params
        sign <- reqGetParamE' "signature"
        tt <- liftM (fmap TimeStampS) $ reqGetParamE' "timestamp"
        nn <- liftM (fmap Nonce) $ reqGetParamE' "nonce"
        let dat = (,,) <$> tt <*> nn <*> sign
            res = dat >>= paramErrorFromEither "signature" . check_sign
        return $ res *> pure ()

withWxppSubLogging ::
    WxppSub
    -> HandlerT MaybeWxppSub (HandlerT master m) a
    -> HandlerT MaybeWxppSub (HandlerT master m) a
withWxppSubLogging foundation h = do
    wxppSubRunLoggingT foundation $ LoggingT $ \log_func -> do
        withLogFuncInHandlerT log_func h

getMessageR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) Text
getMessageR = withWxppSubHandler $ \foundation -> do
    withWxppSubLogging foundation $ do
        checkSignature' foundation
        (httpErrorWhenParamError =<<) $ do
            reqGetParamE' "echostr"

postMessageR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) Text
postMessageR = withWxppSubHandler $ \foundation -> withWxppSubLogging foundation $ do
    checkSignature' foundation
    m_enc_type <- lookupGetParam "encrypt_type"
    enc <- case m_enc_type of
            Nothing -> return False
            Just "" -> return False
            Just "aes" -> return True
            Just x -> do
                        $(logErrorS) wxppLogSource $
                            "unknown/unsupported encrypt_type: " <> x
                        httpErrorRetryWithValidParams $ T.pack $
                            "Retry with valid parameters: encrypt_type(not supported)"
    req <- waiRequest
    lbs <- liftIO $ lazyRequestBody req
    let app_config  = wxppSubAppConfig foundation
        app_id      = wxppAppConfigAppID app_config
        aks         = catMaybes $ wxppConfigAppAesKey app_config :
                                    (map Just $ wxppConfigAppBackupAesKeys app_config)
        app_token   = wxppConfigAppToken app_config


    err_or_resp <- lift $ runExceptT $ do
        (decrypted_xml0, m_enc_akey) <-
            if enc
                then do
                    (either throwE return $ parse_xml_lbs lbs >>= wxppTryDecryptByteStringDocumentE app_id aks)
                        >>= maybe (throwE $ "Internal Error: no AesKey available to decrypt")
                                (return . (LB.fromStrict *** Just))
                else return (lbs, Nothing)

        let err_or_parsed = parse_xml_lbs decrypted_xml0 >>= wxppInMsgEntityFromDocument
        m_ime0 <- case err_or_parsed of
                    Left err -> do
                        $logErrorS wxppLogSource $ fromString $ "Error when parsing incoming XML: " ++ err
                        return Nothing
                    Right x -> return $ Just x

        pre_result <- liftIO $ wxppPreProcessInMsg foundation decrypted_xml0 m_ime0
        case pre_result of
            Left err -> do
                $logErrorS wxppLogSource $ "wxppPreProcessInMsg failed: " <> fromString err
                return ("程序内部错误，请稍后重试", [])

            Right Nothing -> do
                $logDebugS wxppLogSource $ "message handle skipped because middleware return Nothing"
                return ("", [])

            Right (Just (decrypted_xml, m_ime)) -> do
                let handle_msg      = wxppSubMsgHandler foundation
                out_res <- ExceptT $
                        (tryAny $ liftIO $ handle_msg decrypted_xml m_ime)
                            >>= return . either (Left . show) id

                case m_ime of
                    Nothing -> do
                        -- incoming message cannot be parsed
                        -- we don't know who send the message
                        return ("", [])

                    Just me -> do
                        let user_open_id    = wxppInFromUserName me
                            my_name         = wxppInToUserName me

                        let (primary_out_msgs, secondary_out_msgs) = (map snd *** map snd) $ partition fst out_res

                        -- 只要有 primary 的回应，就忽略非primary的回应
                        -- 如果没 primary 回应，而 secondary 回应有多个，则只选择第一个
                        let split_head ls = case ls of
                                            [] -> (Nothing, [])
                                            (x:xs) -> (Just x, xs)
                        let (m_resp_out_msg, other_out_msgs) =
                                if null primary_out_msgs
                                    then (, []) $ listToMaybe $ catMaybes secondary_out_msgs
                                    else split_head $ catMaybes primary_out_msgs

                        now <- liftIO getCurrentTime
                        let mk_out_msg_entity x = WxppOutMsgEntity
                                                    user_open_id
                                                    my_name
                                                    now
                                                    x
                        liftM (, map (user_open_id,) other_out_msgs) $
                            fmap (fromMaybe "") $ forM m_resp_out_msg $ \out_msg -> do
                                liftM (LT.toStrict . renderText def) $ do
                                    let out_msg_entity = mk_out_msg_entity out_msg
                                    case m_enc_akey of
                                        Just enc_akey ->
                                            ExceptT $ wxppOutMsgEntityToDocumentE
                                                            app_id app_token enc_akey out_msg_entity
                                        Nothing ->
                                            return $ wxppOutMsgEntityToDocument out_msg_entity

    case err_or_resp of
        Left err -> do
            $(logErrorS) wxppLogSource $ fromString $
                "cannot encode outgoing message into XML: " <> err
            throwM $ HCError $
                InternalError "cannot encode outgoing message into XML"
        Right (xmls, other_out_msgs) -> do
            when (not $ null other_out_msgs) $ do
                void $ liftIO $ async $ do
                    -- 延迟半秒只要为了让直接回复的回应能第一个到达用户
                    threadDelay $ 1000 * 500
                    wxppSubSendOutMsgs foundation other_out_msgs

            return xmls

    where
        parse_xml_lbs x  = case parseLBS def x of
                                Left ex     -> Left $ "Failed to parse XML: " <> show ex
                                Right xdoc  -> return xdoc


wxppOAuthLoginRedirectUrl :: (MonadHandler m, MonadIO m)
                        => (Route MaybeWxppSub -> [(Text, Text)] -> IO Text)
                        -> WxppAppID
                        -> OAuthScope
                        -> Text             -- ^ optional state: 测试表达微信总是传回一个 state 参数
                                            -- 就算我们我们不传给它 state 参数
                                            -- 所以 state 参数不用 Maybe Text 表达
                        -> UrlText          -- ^ return URL
                        -> m UrlText
wxppOAuthLoginRedirectUrl url_render_io app_id scope state return_url = do
    oauth_retrurn_url <- liftIO $ liftM UrlText $
                            url_render_io OAuthCallbackR [ ("return", unUrlText return_url) ]
    let auth_url = wxppOAuthRequestAuth app_id scope
                        oauth_retrurn_url
                        state
    return auth_url

sessionKeyWxppUser :: WxppAppID -> Text
sessionKeyWxppUser app_id = "wxpp|" <> unWxppAppID app_id

sessionKeyWxppOAuthState :: WxppAppID -> Text
sessionKeyWxppOAuthState app_id = "wxpp-oauth-st|" <> unWxppAppID app_id

sessionMarkWxppUser :: MonadHandler m
                    => WxppAppID
                    -> WxppOpenID
                    -> Text
                    -> m ()
sessionMarkWxppUser app_id open_id state = do
    setSession (sessionKeyWxppUser app_id) (unWxppOpenID open_id)
    let st_key = sessionKeyWxppOAuthState app_id
    if T.null state
        then deleteSession st_key
        else setSession st_key state

sessionGetWxppUser :: MonadHandler m
                    => WxppAppID
                    -> m (Maybe (WxppOpenID, Text))
sessionGetWxppUser app_id = runMaybeT $ do
    (,) <$> ( fmap WxppOpenID $ MaybeT $ lookupSession (sessionKeyWxppUser app_id) )
        <*> ( liftM (fromMaybe "") $ lift $ lookupSession (sessionKeyWxppOAuthState app_id))

getOAuthCallbackR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) Html
getOAuthCallbackR = withWxppSubHandler $ \sub -> do
    m_code <- lookupGetParam "code"
    return_url <- reqPathPieceParamPostGet "return"
    state <- liftM (fromMaybe "") $ lookupGetParam "state"
    let wac    = wxppSubAppConfig sub
        app_id = wxppConfigAppID wac
        secret = wxppConfigAppSecret wac
        cache  = wxppSubCacheBackend sub
    case fmap OAuthCode m_code of
        Just code -> do
            -- 用户同意授权
            err_or_atk_info <- tryWxppWsResult $ wxppOAuthGetAccessToken app_id secret code
            atk_info <- case err_or_atk_info of
                            Left err -> do
                                $logErrorS wxppLogSource $
                                    "wxppOAuthGetAccessToken failed: " <> tshow err
                                throwM $ HCError NotAuthenticated

                            Right x -> return x

            now <- liftIO getCurrentTime
            let expiry  = addUTCTime (oauthAtkTTL atk_info) now
                open_id = oauthAtkOpenID atk_info
                atk_p   = OAuthAccessTokenPkg
                            (oauthAtkToken atk_info)
                            (oauthAtkRefreshToken atk_info)
                            (oauthAtkScopes atk_info)
                            state
                            open_id
                            app_id

            liftIO $ wxppCacheAddOAuthAccessToken cache atk_p expiry

            sessionMarkWxppUser app_id open_id state

            let rdr_url = case parseURI return_url of
                    Just uri ->
                                let qs = uriQuery uri
                                    qs' = case qs of
                                            _   | null qs   -> qs ++ "?"
                                                | qs == "?" -> qs
                                                | otherwise -> qs ++ "&"
                                    new_uri = uri { uriQuery =
                                                        qs' ++ "state=" ++ urlEncode (T.unpack state)
                                                    }
                                in uriToString id new_uri ""

                    _ -> return_url

            -- $logDebugS wxppLogSource $ "redirecting to: " <> T.pack rdr_url
            redirect rdr_url

        Nothing -> do
            -- 授权失败
            defaultLayoutSub $ do
                $(widgetFileReload def "oauth/user_denied")


-- | 测试是否已经过微信用户授权，是则执行执行指定的函数
-- 否则重定向至微信授权页面，待用户授权成功后再重定向回到当前页面
wxppOAuthHandler :: (MonadHandler m, MonadIO m, MonadBaseControl IO m
                , WxppCacheTokenReader c, WxppCacheTemp c)
                => c
                -> (Route MaybeWxppSub -> [(Text, Text)] -> IO Text)
                -> WxppAppID
                -> OAuthScope
                -> Text         -- ^ 调用 oauth 接口的 state 参数（初始值）
                                -- 但真正传给 'f' 的 state 在 OAuthAccessTokenPkg 里
                                -- 未必与前者相同
                -> ( OAuthAccessTokenPkg -> m a )
                -> m a
wxppOAuthHandler cache render_url_io app_id scope state f = do
    m_atk_p <- wxppOAuthHandlerGetAccessTokenPkg cache app_id scope
    case m_atk_p of
        Nothing -> do
            is_wx <- isJust <$> handlerGetWeixinClientVersion
            unless is_wx $ do
                permissionDenied "请用在微信里打开此网页"
            url <- getCurrentUrl
            wxppOAuthLoginRedirectUrl render_url_io app_id scope state (UrlText url)
                >>= redirect . unUrlText
        Just atk_p -> f atk_p


wxppOAuthHandlerGetAccessTokenPkg :: (MonadHandler m, MonadIO m, MonadBaseControl IO m
                                    , WxppCacheTokenReader c, WxppCacheTemp c)
                                    => c
                                    -> WxppAppID
                                    -> OAuthScope
                                    -> m (Maybe OAuthAccessTokenPkg)
wxppOAuthHandlerGetAccessTokenPkg cache app_id scope = do
    m_oauth_st <- sessionGetWxppUser app_id
    case m_oauth_st of
        Nothing -> return Nothing
        Just (open_id, state2) -> do
            m_atk_info <- liftIO $ wxppCacheGetOAuthAccessToken cache
                                        app_id open_id (Set.singleton scope) state2
            case m_atk_info of
                Nothing         -> return Nothing
                Just atk_info   -> return $ Just (packOAuthTokenInfo app_id open_id atk_info)

-- | 演示/测试微信 oauth 授权的页面
getOAuthTestR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) Text
getOAuthTestR = withWxppSubHandler $ \sub -> do
    let wac    = wxppSubAppConfig sub
        app_id = wxppConfigAppID wac
    m_oauth_st <- sessionGetWxppUser app_id
    case m_oauth_st of
        Nothing -> return "no open id, authorization failed"
        Just (open_id, state) -> return $
                            "Your open id is: " <> unWxppOpenID open_id
                                <> ", state is: " <> state


checkWaiReqThen :: Yesod master =>
    (WxppSub -> HandlerT MaybeWxppSub (HandlerT master IO) a)
    -> HandlerT MaybeWxppSub (HandlerT master IO) a
checkWaiReqThen f = withWxppSubHandler $ \foundation -> withWxppSubLogging foundation $ do
    b <- waiRequest >>= liftIO . (wxppSubTrustedWaiReq $ wxppSubOptions foundation)
    if b
        then f foundation
        else permissionDenied "denied by security check"


mimicInvalidAppID :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) a
mimicInvalidAppID = sendResponse $ toJSON $
                        WxppAppError
                            (WxppErrorX $ Right WxppInvalidAppID)
                            "invalid app id"

mimicServerBusy :: Yesod master => Text -> HandlerT MaybeWxppSub (HandlerT master IO) a
mimicServerBusy s = sendResponse $ toJSON $
                        WxppAppError
                            (WxppErrorX $ Right WxppServerBusy)
                            s

forwardWsResult :: (Yesod master, ToJSON a) =>
    String -> Either WxppWsCallError a -> HandlerT MaybeWxppSub (HandlerT master IO) Value
forwardWsResult op_name res = do
    case res of
        Left (WxppWsErrorApp err) -> do
            sendResponse $ toJSON err

        Left err -> do
            $logError $ fromString $
                op_name ++ " failed: " ++ show err
            mimicServerBusy $ fromString $ op_name ++ " failed"

        Right x -> do
            return $ toJSON x

-- | 提供 access-token
-- 为重用代码，错误报文格式与微信平台接口一样
-- 逻辑上的返回值是 AccessToken
getGetAccessTokenR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) Value
getGetAccessTokenR = checkWaiReqThen $ \foundation -> do
    alreadyExpired
    liftM toJSON $ getAccessTokenSubHandler' foundation


-- | 找 OpenID 对应的 UnionID
-- 为重用代码，错误报文格式与微信平台接口一样
-- 逻辑上的返回值是 Maybe WxppUnionID
getGetUnionIDR :: Yesod master => WxppOpenID -> HandlerT MaybeWxppSub (HandlerT master IO) Value
getGetUnionIDR open_id = checkWaiReqThen $ \foundation -> do
    alreadyExpired
    let sm_mode = wxppSubMakeupUnionID $ wxppSubOptions foundation
    if sm_mode
        then do
            return $ toJSON $ Just $ fakeUnionID open_id
        else do
            let app_id = wxppAppConfigAppID $ wxppSubAppConfig foundation
            let cache = wxppSubCacheBackend foundation

            (tryWxppWsResult $ liftIO $ wxppCacheLookupUserInfo cache app_id open_id)
                >>= forwardWsResult "wxppCacheLookupUserInfo"


-- | 初始化 WxppUserCachedInfo 表的数据
getInitCachedUsersR :: Yesod master =>
    HandlerT MaybeWxppSub (HandlerT master IO) Value
getInitCachedUsersR = checkWaiReqThen $ \foundation -> do
    alreadyExpired
    atk <- getAccessTokenSubHandler' foundation

    _ <- liftIO $ forkIO $ wxppSubRunLoggingT foundation $ do
                _ <- runWxppDB (wxppSubRunDBAction foundation) $ initWxppUserDbCacheOfApp atk
                return ()

    return $ toJSON ("run in background" :: Text)


-- | 为客户端调用平台的 wxppQueryEndUserInfo 接口
-- 逻辑返回值是 EndUserQueryResult
getQueryUserInfoR :: Yesod master => WxppOpenID -> HandlerT MaybeWxppSub (HandlerT master IO) Value
getQueryUserInfoR open_id = checkWaiReqThen $ \foundation -> do
    alreadyExpired
    atk <- getAccessTokenSubHandler' foundation
    let sm_mode = wxppSubMakeupUnionID $ wxppSubOptions foundation
        fix_uid qres =
            if sm_mode
                then endUserQueryResultSetUnionID (Just $ fakeUnionID open_id) <$> qres
                else qres
    (tryWxppWsResult $ wxppQueryEndUserInfo atk open_id)
        >>= return . fix_uid
        >>= forwardWsResult "wxppQueryEndUserInfo"

-- | 模仿创建永久场景的二维码
-- 行为接近微信平台的接口，区别是
-- 输入仅仅是一个 WxppScene
postCreateQrCodePersistR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) Value
postCreateQrCodePersistR = checkWaiReqThen $ \foundation -> do
    alreadyExpired
    scene <- decodePostBodyAsYaml
    let sm_mode = wxppSubFakeQRTicket $ wxppSubOptions foundation
    if sm_mode
        then do
            qrcode_base_url <- withUrlRenderer $ \render ->
                                    render ShowSimulatedQRCodeR []

            let fake_ticket = (scene, qrcode_base_url)
            return $ toJSON $ C8.unpack $ B64L.encode $ LB.toStrict $ A.encode fake_ticket

        else do
            atk <- getAccessTokenSubHandler' foundation
            liftM toJSON $ wxppQrCodeCreatePersist atk scene


-- | 返回一个二维码图像
-- 其内容是 WxppScene 用 JSON 格式表示之后的字节流
getShowSimulatedQRCodeR :: Yesod master => HandlerT MaybeWxppSub (HandlerT master IO) TypedContent
getShowSimulatedQRCodeR = do
    ticket_s <- lookupGetParam "ticket"
                >>= maybe (httpErrorRetryWithValidParams ("missing ticket" :: Text)) return

    (ticket :: FakeQRTicket) <- case B64L.decode (C8.pack $ T.unpack ticket_s) of
        Left _ -> httpErrorRetryWithValidParams ("invalid ticket" :: Text)
        Right bs -> case decodeEither' bs of
                        Left err -> do
                            $logError $ fromString $
                                "cannot decode request body as YAML: " ++ show err
                            sendResponseStatus (mkStatus 449 "Retry With") $
                                ("retry wtih valid request JSON body" :: Text)

                        Right (x, y) -> return (x, UrlText y)

    let scene = fst ticket
    let input = C8.unpack $ LB.toStrict $ A.encode scene
    bs <- encodeStringQRCodeJpeg 5 input
    return $ toTypedContent (typeSvg, toContent bs)


-- | 返回与输入的 union id 匹配的所有 open id 及 相应的 app_id
getLookupOpenIDByUnionIDR :: Yesod master =>
    WxppUnionID
    -> HandlerT WxppSubNoApp (HandlerT master IO) Value
getLookupOpenIDByUnionIDR union_id = checkWaiReqThenNA $ \foundation -> do
    alreadyExpired
    liftM toJSON $ liftIO $ wxppSubNoAppUnionIdByOpenId foundation union_id


instance Yesod master => YesodSubDispatch MaybeWxppSub (HandlerT master IO)
    where
        yesodSubDispatch = $(mkYesodSubDispatch resourcesMaybeWxppSub)


instance Yesod master => YesodSubDispatch WxppSubNoApp (HandlerT master IO)
    where
        yesodSubDispatch = $(mkYesodSubDispatch resourcesWxppSubNoApp)

--------------------------------------------------------------------------------

checkWaiReqThenNA :: Yesod master =>
    (WxppSubNoApp -> HandlerT WxppSubNoApp (HandlerT master IO) a)
    -> HandlerT WxppSubNoApp (HandlerT master IO) a
checkWaiReqThenNA f = do
    foundation <- getYesod
    wxppSubNoAppRunLoggingT foundation $ LoggingT $ \log_func -> do
        withLogFuncInHandlerT log_func $ do
            b <- waiRequest >>= liftIO . wxppSubNoAppCheckWaiReq foundation
            if b
                then f foundation
                else permissionDenied "denied by security check"

decodePostBodyAsYaml :: (Yesod master, FromJSON a) =>
    HandlerT MaybeWxppSub (HandlerT master IO) a
decodePostBodyAsYaml = do
    body <- rawRequestBody $$ sinkLbs
    case decodeEither' (LB.toStrict body) of
        Left err -> do
            $logError $ fromString $
                "cannot decode request body as YAML: " ++ show err
            sendResponseStatus (mkStatus 449 "Retry With") $
                ("retry wtih valid request JSON body" :: Text)

        Right x -> return x


getAccessTokenSubHandler' :: Yesod master =>
    WxppSub -> HandlerT MaybeWxppSub (HandlerT master IO) AccessToken
getAccessTokenSubHandler' foundation = do
    let cache = wxppSubCacheBackend foundation
    let app_id = wxppAppConfigAppID $ wxppSubAppConfig foundation
    (liftIO $ wxppCacheGetAccessToken cache app_id)
            >>= maybe (mimicServerBusy "no access token available") (return . fst)


fakeUnionID :: WxppOpenID -> WxppUnionID
fakeUnionID (WxppOpenID x) = WxppUnionID $ "fu_" <> x


-- | initialize db table: WxppUserCachedInfo
initWxppUserDbCacheOfApp ::
    ( MonadIO m, MonadLogger m, MonadThrow m) =>
    AccessToken -> ReaderT WxppDbBackend m Int
initWxppUserDbCacheOfApp atk = do
    wxppGetEndUserSource atk
        =$= CL.concatMap wxppOpenIdListInGetUserResult
        =$= save_to_db
        $$ CC.length
    where
        app_id = accessTokenApp atk

        save_to_db = awaitForever $ \open_id -> do
            now <- liftIO getCurrentTime
            _ <- lift $ do
                m_old <- getBy $ UniqueWxppUserCachedInfo open_id app_id
                case m_old of
                    Just _ -> do
                        -- 假定 open id 及 union id 对于固定的 app 是固定的
                        -- 已有的记录暂时不更新了
                        -- 因为调用平台接口有点慢
                        return ()

                    Nothing -> do
                        qres <- wxppQueryEndUserInfo atk open_id
                        _ <- insertBy $ WxppUserCachedInfo app_id
                                (endUserQueryResultOpenID qres)
                                (endUserQueryResultUnionID qres)
                                now
                        return ()

                transactionSave

            yield ()

