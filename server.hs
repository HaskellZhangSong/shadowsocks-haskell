{-# LANGUAGE OverloadedStrings #-}

import           Control.Applicative ((<$>))
import           Control.Concurrent (forkFinally)
import           Control.Concurrent.Async (concurrently)
import qualified Control.Exception as E
import           Control.Monad (forever, void, when, unless)
import           Data.Char (ord)
import           Data.Binary.Get (runGet, getWord16be, getWord32le)
import           Data.ByteString (ByteString)
import qualified Data.ByteString as S
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Char8 as C
import           Data.Monoid ((<>))
import           GHC.IO.Handle (hSetBuffering, BufferMode(NoBuffering))
import           GHC.IO.Handle.FD (stdout)
import           Network.Socket hiding (recv)
import           Network.Socket.ByteString (recv, sendAll)

import Shadowsocks.Encrypt (getEncDec, iv_len)
import Shadowsocks.Util

main :: IO ()
main = withSocketsDo $ do
    config <- parseConfigOptions
    addrinfos <- getAddrInfo (Just (defaultHints {addrFlags = [AI_PASSIVE]}))
                             Nothing
                             (Just $ show $ server_port config)
    let sockAddr = head addrinfos
    sock <- socket (addrFamily sockAddr) Stream defaultProtocol
    bindSocket sock (addrAddress sockAddr)
    listen sock 128
    hSetBuffering stdout NoBuffering

    C.hPutStrLn stdout $
        "starting server at " <> C.pack (show $ server_port config)
    serveForever sock config

serveForever :: Socket -> Config -> IO ()
serveForever sock config = forever $ do
    (conn, _) <- accept sock
    forkFinally (sockHandler conn config)
                (\_ -> close conn)

sockHandler :: Socket -> Config -> IO ()
sockHandler conn config =
    (do
        (encrypt, decrypt) <- getEncDec (method config) (password config)
        let methodName = method config
        when (methodName /= "table")
             (void $ recv conn (iv_len methodName) >>= decrypt)
        addrType <- recv conn 1 >>= decrypt

        addr <- if ord (head $ C.unpack addrType) == 1
            then do
                addr_ip <- recv conn 4 >>= decrypt
                inet_ntoa $ runGet getWord32le $ L.fromStrict addr_ip
            else do
                addr_len <- recv conn 1 >>= decrypt
                addr <- recv conn (ord $ head $ C.unpack addr_len) >>= decrypt
                return $ C.unpack addr

        addr_port <- recv conn 2 >>= decrypt
        let port = runGet getWord16be $ L.fromStrict addr_port

        remoteAddr <- head <$>
            getAddrInfo Nothing (Just addr) (Just $ show port)
        remote <- socket (addrFamily remoteAddr) Stream defaultProtocol
        connect remote (addrAddress remoteAddr)
        putStrLn $ "connecting " <> addr <> ":" <> show port
        handleTCP conn remote encrypt decrypt)
        `E.catch` (\e -> void $ print (e :: E.SomeException))

handleTCP :: Socket
          -> Socket
          -> (ByteString -> IO ByteString)
          -> (ByteString -> IO ByteString)
          -> IO ()
handleTCP conn remote encrypt decrypt = do
    concurrently handleLocal handleRemote
    close remote
  where
    handleLocal = do
        inData <- recv conn 4096 >>= decrypt
        unless (S.null inData) $ sendAll remote inData >> handleLocal
    handleRemote = do
        inData <- recv remote 4096 >>= encrypt
        unless (S.null inData) $ sendAll conn inData >> handleRemote
