{-# LANGUAGE OverloadedStrings #-}

module Main where

import Network.Socket hiding (send, recv)
import Network.Socket.ByteString
import Control.Concurrent
import Control.Monad
import qualified Data.ByteString as B
import Control.Concurrent.MVar

main :: IO ()
main = do
    sock <- socket AF_INET Stream defaultProtocol
    bind sock $ SockAddrInet 8888 iNADDR_ANY
    listen sock 32768
    forever $ do
        (sock' , addr) <- accept sock
        forkIO $ do
            forever $ do
                _ <- recv sock' 2048
                sendAll sock' sendbuf
  where
    sendbuf =
        "HTTP/1.1 200 OK\r\n\
        \Content-Type: text/html; charset=UTF-8\r\n\
        \Content-Length: 5000\r\n\
        \Connection: Keep-Alive\r\n\
        \\r\n" `B.append` (B.replicate 5000 48)

