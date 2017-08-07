{-# LANGUAGE OverloadedStrings #-}
module Main where

import System.IO.Handle
import System.IO.Socket.Base
import System.IO.Socket.Address
import Control.Concurrent
import Foreign
import qualified Data.ByteString as B
import qualified Data.ByteString.Internal as B
import GHC.ForeignPtr
import Control.Monad
import Data.IORef.Unboxed

main :: IO ()
main = do
    sock <- socket aF_INET sOCK_STREAM iPPROTO_TCP
    b <- bind sock $ SockAddrInet (fromIntegral 8888) inetAny
    l <- listen b 32768
    forever $ do
        sock' <- accept l
        forkIO $ do
            tcp <- newTCP sock'
            forever $ do
                recvbuf <- mallocPlainForeignPtrBytes 2048
                withForeignPtr recvbuf $ \ p -> do
                    _ <- readInput tcp p 2048
                    return ()

                let (B.PS sendbuffp _ l) = sendbuf
                withForeignPtr sendbuffp $ \ p ->
                    writeOutput tcp p l

  where
    sendbuf =
        "HTTP/1.1 200 OK\r\n\
        \Content-Type: text/html; charset=UTF-8\r\n\
        \Content-Length: 5000\r\n\
        \Connection: Keep-Alive\r\n\
        \\r\n" `B.append` (B.replicate 5000 48)




