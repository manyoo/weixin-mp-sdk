{-# LANGUAGE ScopedTypeVariables #-}
module WeiXin.PublicPlatform.Conversation
    ( module WeiXin.PublicPlatform.Conversation
    , module Text.Parsec.Text
    , module Text.Parsec.Error
    , module Text.Parsec.Prim
    ) where

import ClassyPrelude

import Control.Monad.State.Strict hiding (mapM_)
import Control.Monad.Trans.Except
import Data.Conduit
import Control.Monad.Logger
import qualified Data.Conduit.List          as CL

import Text.Parsec.Text
import Text.Parsec.Error
import Text.Parsec.Pos                      (initialPos)
import Text.Parsec.Prim
import Data.Aeson.TH                        (deriveJSON, defaultOptions)

import WeiXin.PublicPlatform.Types
import WeiXin.PublicPlatform.InMsgHandler

class TalkerState a where
    talkPromptNext :: a -> (Maybe Text, a)

    talkNotUnderstanding :: a -> ParseError -> (Maybe Text, a)

    -- | 解释出 Nothing 代表对话结束
    talkParser :: a -> Parser (Maybe Text, a)

    talkDone :: a -> Bool


data SomeTalkerState = forall a. TalkerState a => SomeTalkerState a

instance TalkerState SomeTalkerState where
    talkPromptNext (SomeTalkerState x)          = second SomeTalkerState $ talkPromptNext x
    talkNotUnderstanding (SomeTalkerState x)    = second SomeTalkerState . talkNotUnderstanding x
    talkParser (SomeTalkerState x)              = second SomeTalkerState <$> talkParser x
    talkDone (SomeTalkerState x)                = talkDone x


talkerRun :: (Monad m, TalkerState a) =>
    (m a)
    -> (a -> m ())
    -> Conduit Text m Text
talkerRun = talkerRun' False

talkerRun' :: (Monad m, TalkerState a) =>
    Bool
    -> (m a)
    -> (a -> m ())
    -> Conduit Text m Text
talkerRun' skip_first_prompt get_state put_state =
    if skip_first_prompt
        then chk_wait_and_go
        else go
    where
        prompt = do
            st <- lift get_state
            let (m_t, s) = talkPromptNext st
            maybe (return ()) yield m_t
            lift $ put_state s

        go = prompt >> chk_wait_and_go

        chk_wait_and_go = do
            done <- liftM talkDone $ lift get_state
            if done
                then return ()
                else wait_and_go

        wait_and_go = do
            mx <- await
            case mx of
                Nothing -> return ()
                Just t  -> do
                    st <- lift get_state
                    case parse (talkParser st) "" t of
                        Left err -> do
                            let (m_t, ms) = talkNotUnderstanding st err
                            maybe (return ()) yield m_t
                            lift $ put_state ms

                        Right (m_reply, new_st) -> do
                            maybe (return ()) yield m_reply
                            lift $ put_state new_st
                    go


talkerStateRunner :: (Monad m, TalkerState a) =>
    Conduit Text (StateT a m) Text
talkerStateRunner = talkerRun get put


-- | 为Yesod应用而设计
-- 实际程序中，会话是通过无状态的连接实现的，所以需要一种保存状态的接口
-- 这个函数负责处理一次用户输入
conversationInputOneStep :: (Monad m, TalkerState s) =>
    m s                 -- ^ get state
    -> (s -> m ())      -- ^ set state
    -> Maybe Text
        -- ^ 新建立的会话时，用户输入理解为 Nothing
        -- 之后的调用都应该是 Just
    -> m [Text]
        -- ^ 状态机的输出文字
conversationInputOneStep get_st set_st m_input = do
    let send_intput = case m_input of
                        Nothing -> return ()
                        Just x -> yield x
    let cond = talkerRun' (isJust m_input) get_st set_st
    send_intput =$= cond $$ CL.consume


type WxTalkerMonad r m = ReaderT r (ExceptT String m)

mkWxTalkerMonad :: Monad m => (r -> m (Either String a)) -> WxTalkerMonad r m a
mkWxTalkerMonad f = do
    env <- ask
    lift $ ExceptT $ f env

runWxTalkerMonad :: Monad m => WxTalkerMonad r m a -> r -> m (Either String a)
runWxTalkerMonad f env = runExceptT $ runReaderT f env

runWxTalkerMonadE :: Monad m => WxTalkerMonad r m a -> r -> ExceptT String m a
runWxTalkerMonadE = runReaderT

-- | 支持更多操作的接口: 例如可以使用 IO 之类
-- 处理的用户输入也不仅仅是文字输入
class WxTalkerState r m a where
    -- | 为用户下一个输入提供提示
    -- 注意：这个方法会在 wxTalkHandleInput 之后调用
    wxTalkPromptToInput ::  a
                            -> WxTalkerMonad r m ([WxppOutMsg], a)
                            -- ^ 回应消息及新的状态

    -- | 处理用户的输入，并产生结果
    -- 在会话过程中，消息可能会被无条件传入这个函数处理
    -- 要表达这个函数是否真正有处理用户输入，因此结果是个 Maybe
    wxTalkHandleInput :: a
                        -> WxppInMsgEntity
                        -> WxTalkerMonad r m ([WxppOutMsg], a)

    -- | 判断对话是否已结束
    wxTalkIfDone :: a
                    -> WxTalkerMonad r m Bool


class WxTalkerDoneAction r m a where
    wxTalkDone :: a -> WxTalkerMonad r m [WxppOutMsg]


wxTalkerRun :: (Monad m, Eq a, WxTalkerState r m a) =>
    Bool
    -> (WxTalkerMonad r m a)
    -> (a -> WxTalkerMonad r m ())
    -> Conduit WxppInMsgEntity (WxTalkerMonad r m) WxppOutMsg
wxTalkerRun skip_first_prompt get_state put_state =
    if skip_first_prompt
        then chk_wait_and_go
        else go
    where
        prompt = do
            st <- lift $ get_state
            (replies, new_st) <- lift $ wxTalkPromptToInput st
            mapM_ yield replies
            unless (st == new_st) $ do
                lift $ put_state new_st

        go = prompt >> chk_wait_and_go

        chk_wait_and_go = do
            done <- lift $ get_state >>= wxTalkIfDone
            if done
                then return ()
                else wait_and_go

        wait_and_go = do
            mx <- await
            case mx of
                Nothing -> return ()
                Just t  -> do
                    st <- lift $ get_state
                    (replies, new_st) <- lift $ wxTalkHandleInput st t
                    mapM_ yield replies
                    unless (st == new_st) $ do
                        lift $ put_state new_st
                    go


wxTalkerInputOneStep :: (Monad m, WxTalkerState r m s, Eq s) =>
    WxTalkerMonad r m s                 -- ^ get state
    -> (s -> WxTalkerMonad r m ())      -- ^ set state
    -> r
    -> Maybe WxppInMsgEntity
        -- ^ 新建立的会话时，用户输入理解为 Nothing
        -- 之后的调用都应该是 Just
    -> m (Either String [WxppOutMsg])
        -- ^ 状态机的输出文字
wxTalkerInputOneStep get_st set_st env m_input = flip runWxTalkerMonad env $ do
    send_intput =$= cond $$ CL.consume
    where
        send_intput = case m_input of
                        Nothing -> return ()
                        Just x -> yield x
        cond = wxTalkerRun (isJust m_input) get_st set_st


-- | used to implement processInMsg of class IsWxppInMsgProcessor
-- 用于处理会话建立后的消息处理
wxTalkerInputProcessInMsg :: forall m r s .
    (MonadIO m, Eq s
    , WxTalkerState r m s
    , WxTalkerDoneAction r m s
    ) =>
    (WxppOpenID -> WxTalkerMonad r m s)             -- ^ get state
    -> (WxppOpenID -> s -> WxTalkerMonad r m ())    -- ^ set state
    -> r
    -> Maybe WxppInMsgEntity
        -- ^ this is nothing only if caller cannot parse the message
    -> m (Either String WxppInMsgHandlerResult)
wxTalkerInputProcessInMsg get_st set_st env m_ime = runExceptT $ do
    case m_ime of
        Nothing -> return []
        Just ime -> do
            let open_id = wxppInFromUserName ime
            (get_st', set_st') <- ioCachedGetSet (get_st open_id) (set_st open_id)
            st <- run_wx_monad $ get_st'
            done <- run_wx_monad $ wxTalkIfDone st
            if done
                then do
                    -- not in conversation
                    return []

                else do
                    msgs <- ExceptT $ wxTalkerInputOneStep get_st' set_st' env m_ime
                    new_st <- run_wx_monad $ get_st'
                    done2 <- run_wx_monad $ wxTalkIfDone new_st
                    msgs2 <- if done2
                                then run_wx_monad $ wxTalkDone new_st
                                else return []
                    return $ (map $ (True,) . Just) $ msgs <> msgs2
    where
        run_wx_monad :: forall a. WxTalkerMonad r m a -> ExceptT String m a
        run_wx_monad = flip runWxTalkerMonadE env


-- 用于处理会话刚刚建立，产生一些输出消息
wxTalkerInputProcessJustInited :: forall m r s .
    (MonadIO m, MonadLogger m, Eq s
    , WxTalkerState r m s
    , WxTalkerDoneAction r m s
    ) =>
    (WxTalkerMonad r m s)               -- ^ get state
    -> (s -> WxTalkerMonad r m ())      -- ^ set state
    -> r
    -> m (Either String WxppInMsgHandlerResult)
wxTalkerInputProcessJustInited get_st set_st env = runExceptT $ do
    (get_st', set_st') <- ioCachedGetSet get_st set_st
    st <- run_wx_monad $ get_st'
    done <- run_wx_monad $ wxTalkIfDone st
    if done
        then do
            -- not in conversation
            $logWarn $ "inited state is done?"
            return []

        else do
            msgs <- ExceptT $ wxTalkerInputOneStep get_st' set_st' env Nothing
            new_st <- run_wx_monad $ get_st'
            done2 <- run_wx_monad $ wxTalkIfDone new_st
            msgs2 <- if done2
                        then run_wx_monad $ wxTalkDone new_st
                        else return []
            return $ (map $ (True,) . Just) $ msgs <> msgs2
    where
        run_wx_monad :: forall a. WxTalkerMonad r m a -> ExceptT String m a
        run_wx_monad = flip runWxTalkerMonadE env


-- | 这个小工具用于减少 getter, setter 访问数据库
-- 前提：状态的读写是单线程的
ioCachedGetSet :: (MonadIO m, MonadIO n) =>
    m s
    -> (s -> m ())
    -> n (m s, s -> m ())
        -- ^ 新的 getter, setter
ioCachedGetSet get_f set_f = do
    ior <- liftIO $ newIORef Nothing
    let set_f' x = do
            set_f x
            liftIO $ writeIORef ior $ Just x

    let get_f' = (liftIO $ readIORef ior) >>= maybe get_f return

    return (get_f', set_f')


newtype WrapTalkerState a = WrapTalkerState a
                            deriving (Eq)

instance (Eq a, TalkerState a, Monad m) => WxTalkerState r m (WrapTalkerState a) where
    wxTalkPromptToInput (WrapTalkerState s) = mkWxTalkerMonad $ \_ -> runExceptT $ do
        let (m_reply, new_s) = talkPromptNext s
        return $ (maybe [] (return . WxppOutMsgText) m_reply, WrapTalkerState new_s)

    wxTalkHandleInput (WrapTalkerState s) ime = mkWxTalkerMonad $ \_ -> runExceptT $ do
        case wxppInMessage ime of
            WxppInMsgText t -> do
                case parse (talkParser s) "" t of
                    Left err -> do
                        let (m_t, new_s) = talkNotUnderstanding s err
                        return $ (maybe [] (return . WxppOutMsgText) m_t, WrapTalkerState new_s)

                    Right (m_t, new_s) -> do
                        return $ (maybe [] (return . WxppOutMsgText) m_t, WrapTalkerState new_s)

            _ -> do
                let err = newErrorMessage (Message "unknown weixin message") (initialPos "")
                let (m_t, new_s) = talkNotUnderstanding s err
                return $ (maybe [] (return . WxppOutMsgText) m_t, WrapTalkerState new_s)

    wxTalkIfDone (WrapTalkerState s) = mkWxTalkerMonad $ const $ return $ Right $ talkDone s


-- | as a place holder
data NullTalkerState = NullTalkerState
                        deriving (Eq, Ord, Enum, Bounded)

$(deriveJSON defaultOptions ''NullTalkerState)

instance Monad m => WxTalkerState r m NullTalkerState where
    wxTalkPromptToInput x   = mkWxTalkerMonad $ \_ -> runExceptT $ return $ ([], x)
    wxTalkHandleInput   x _ = mkWxTalkerMonad $ \_ -> runExceptT $ return $ ([], x)
    wxTalkIfDone        _   = mkWxTalkerMonad $ \_ -> runExceptT $ return $ True

instance Monad m => WxTalkerDoneAction r m NullTalkerState where
    wxTalkDone _ = mkWxTalkerMonad $ \_ -> return $ Right []


{-
data SomeWxTalkerState m = forall a. (WxTalkerState m a, WxTalkerDoneAction m a) =>
                                SomeWxTalkerState a

instance Monad m => WxTalkerState m (SomeWxTalkerState m) where
    wxTalkPromptToInput cache (SomeWxTalkerState x) = liftM (fmap $ second SomeWxTalkerState) $
                                                            wxTalkPromptToInput cache x

    wxTalkHandleInput cache (SomeWxTalkerState x)   = liftM (fmap $ second SomeWxTalkerState) .
                                                        wxTalkHandleInput cache x

    wxTalkIfDone cache (SomeWxTalkerState x)        = wxTalkIfDone cache x


instance WxTalkerDoneAction m (SomeWxTalkerState m) where
    wxTalkDone cache (SomeWxTalkerState x) = wxTalkDone cache x
--}
