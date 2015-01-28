module WeiXin.PublicPlatform.Error where

import ClassyPrelude
import Data.Monoid                          (First(..))


-- | 这是已能被识别的错误代码
-- 这个列表尽量完整，但不必完整
data WxppError = WxppServerBusy
                | WxppNoError
                | WxppInvalidAppSecret
                | WxppInvalidAccessToken
                | WxppInvalidTokenType
                | WxppInvalidOpenID
                | WxppInvalidMediaFileType
                | WxppInvalidAppID
                | WxppSystemError
                deriving (Show, Typeable, Eq, Ord, Enum, Bounded)

wxppToErrorCode :: WxppError -> Int
wxppToErrorCode WxppServerBusy              = -1
wxppToErrorCode WxppNoError                 = 0
wxppToErrorCode WxppInvalidAppSecret        = 40001
wxppToErrorCode WxppInvalidTokenType        = 40002
wxppToErrorCode WxppInvalidOpenID           = 40003
wxppToErrorCode WxppInvalidMediaFileType    = 40004
wxppToErrorCode WxppInvalidAppID            = 40013
wxppToErrorCode WxppInvalidAccessToken      = 40014
wxppToErrorCode WxppSystemError             = 61450


-- | 不能被识别的代码放在Left里，能识别的放在Right里
newtype WxppErrorX = WxppErrorX { unWxppErrorX :: Either Int WxppError }
                    deriving (Show, Eq, Typeable)

instance Exception WxppErrorX


wxppFromErrorCode :: Int -> WxppErrorX
wxppFromErrorCode ec = WxppErrorX $
    fromMaybe (Left ec) $
        getFirst $ mconcat $ map First known_lst
    where
        known_lst = flip map [minBound .. maxBound] $ \err ->
                        if wxppToErrorCode err == ec
                            then Just (Right err)
                            else Nothing


wxppToErrorCodeX :: WxppErrorX -> Int
wxppToErrorCodeX = either id wxppToErrorCode . unWxppErrorX
