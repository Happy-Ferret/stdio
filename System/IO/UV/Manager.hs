{-# LANGUAGE BangPatterns #-}

{-|
Module      : System.IO.UV.Manager
Description : I/O manager based on libuv
Copyright   : (c) Winterland, 2017
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : non-portable

This module provide I/O manager which bridge libuv's async interface with ghc's light weight thread.

-}

module System.IO.UV.Manager where

import GHC.Stack.Compat
import qualified System.IO.UV.Exception as E
import qualified System.IO.Exception as E
import Data.Array
import Data.Primitive.PrimArray
import Data.Word
import Data.IORef
import Data.IORef.Unboxed
import Foreign hiding (void)
import Foreign.C
import Control.Concurrent.MVar
import Control.Concurrent
import Control.Monad
import Data.Primitive.Addr
import System.IO.Unsafe
import System.IO.UV.Base

--------------------------------------------------------------------------------

data UVManager = UVManager
    { uvmBlockTable  :: IORef (Array (MVar ()))     -- a array to store thread blocked on read or write

    , uvmFreeSlotList :: MVar [Int]                 -- we generate two unique range limited 'Int' /slot/
                                                    -- for each uv_handle_t(one for read and another for
                                                    -- write).
                                                    --
                                                    -- the slot is attached as the data field of
                                                    -- c struct uv_handle_t, thus will be available
                                                    -- to c callbacks, which are static functions:
                                                    -- inside callback we increase event counter and
                                                    -- push slot into event queue
                                                    --
                                                    -- after uv_run is finished, we read the counter
                                                    -- and the queue back, use the slots in the queue
                                                    -- as index to unblock thread in block queue
                                                    --
                                                    -- We also use this 'MVar' to do finalization of
                                                    -- I/O manager by attaching finalizers to it with 'mkWeakMVar'

    , uvmLoop        :: Ptr UVLoop                  -- the uv loop refrerence
    , uvmLoopData    :: Ptr UVLoopData              -- This is the pointer to uv_loop_t's data field

    , uvmRunningLock :: MVar Bool                   -- during uv_run this lock shall be held!
                                                    -- unlike epoll/ONESHOT, uv loop are NOT thread safe,
                                                    -- thus we can only add new event when uv_run is not
                                                    -- running, usually this is not a problem because
                                                    -- unsafe FFI can't run concurrently on one
                                                    -- capability, but with work stealing we'd better
                                                    -- ask for this lock before calling any uv APIs.

    , uvmIdleCounter :: Counter                     -- Counter for idle(no event) uv_runs, when counter
                                                    -- reaches 10, we start to increase waiting between
                                                    -- uv_run, until delay reach 8 milliseconds

    , uvmCap :: Int                                 -- the capability uv manager should run on, we save this
                                                    -- number for restarting uv manager
    }

initTableSize :: Int
initTableSize = 128

uvManager :: IORef (Array UVManager)
uvManager = unsafePerformIO $ do
    numCaps <- getNumCapabilities
    uvmArray <- newArr numCaps
    forM [0..numCaps-1] $ \ i -> do
        writeArr uvmArray i =<< newUVManager initTableSize i
    iuvmArray <- unsafeFreezeArr uvmArray
    newIORef iuvmArray

getUVManager :: IO UVManager
getUVManager = do
    (cap, _) <- threadCapability =<< myThreadId
    uvmArray <- readIORef uvManager
    indexArrM uvmArray (cap `rem` sizeofArr uvmArray)

newUVManager :: HasCallStack => Int -> Int -> IO UVManager
newUVManager siz cap = do

    mblockTable <- newArr siz
    forM_ [0..siz-1] $ \ i ->
        writeArr mblockTable i =<< newEmptyMVar
    blockTable <- unsafeFreezeArr mblockTable
    blockTableRef <- newIORef blockTable

    freeSlotList <- newMVar [0..siz-1]

    loop <- E.throwOOMIfNull callStack "malloc loop and data for uv manager" $
        hs_loop_init (fromIntegral siz)

    loopData <- peek_uv_loop_data loop

    loopLock <- newMVar False

    idleCounter <- newCounter 0

    _ <- mkWeakMVar loopLock $ do
        hs_loop_close loop

    return (UVManager blockTableRef freeSlotList loop loopData loopLock idleCounter cap)

-- | libuv is not thread safe, use this function to perform handle/request initialization.
--
withUVManager :: HasCallStack => UVManager -> (Ptr UVLoop -> IO a) -> IO a
withUVManager uvm f = withMVar (uvmRunningLock uvm) $ \ _ -> f (uvmLoop uvm)

-- | libuv is not thread safe, use this function to start reading/writing.
--
-- This function also take care of restart uv manager in case of stopped.
--
withUVManagerEnsureRunning :: HasCallStack => UVManager -> IO a -> IO a
withUVManagerEnsureRunning uvm f = modifyMVar (uvmRunningLock uvm) $ \ running -> do
    r <- f
    unless running $ do
        void $ forkOn (uvmCap uvm) (startUVManager uvm)
    return (True, r)

-- | Start the uv loop, the loop is stopped when there're not active I/O requests.
--
-- Inside loop, we never do block waiting like the io manager in Mio does,
-- we take the golang net poller's approach instead:
-- simply run non-block poll with a bound increasing delay, the reason is that libuv's APIs is
-- generally not thread safe: you shouldn't add or remove events during uv_run,
-- which makes safe blocking poll problematic, because doing that will requrie us to do some thread
-- safe notification, and that's too complex.
--
startUVManager :: UVManager -> IO ()
startUVManager uvm = do
    continue <- modifyMVar (uvmRunningLock uvm) $ \ _ -> do
        c <- uv_loop_alive(uvmLoop uvm)     -- we're holding the uv lock so no more new request can be add here
        if (c /= 0)
        then do
            let idleCounter = uvmIdleCounter uvm
            e <- step uvm
            ic <- readIORefU idleCounter
            if (e == 0)                     -- bump the idle counter if no events, there's no need to do atomic-ops
            then when (ic < 16) $ writeIORefU idleCounter (ic+1)
            else writeIORefU idleCounter 0

            return (True, True)
        else
            return (False, False)

    -- If not continue, new events will find running is locking on 'False'
    -- and fork new uv manager thread.
    when continue $ do
        let idleCounter = uvmIdleCounter uvm
        ic <- readIORefU idleCounter
        if (ic >= 2)                    -- we yield 2 times, then start to delay 1ms, 2ms ... up to 8 ms.
        then threadDelay $ (ic `quot` 2) * 1000
        else yield
        startUVManager uvm

  where
    -- call uv_run, return the event number
    --
    step :: UVManager -> IO CSize
    step (UVManager blockTableRef freeSlotList loop loopData _ _ _) = do
            blockTable <- readIORef blockTableRef

            clearUVEventCounter loopData
            (c, q) <- peekUVEventQueue loopData

            E.throwUVErrorIfMinus callStack "uv manager uv_run" $ uv_run loop uV_RUN_NOWAIT

            (c, q) <- peekUVEventQueue loopData
            forM_ [0..(fromIntegral c-1)] $ \ i -> do
                slot <- peekElemOff q i
                lock <- indexArrM blockTable (fromIntegral slot)
                void $ tryPutMVar lock ()

            return c

allocSlot :: UVManager -> IO Int
allocSlot (UVManager blockTableRef freeSlotList loop _ _ _ _) = do
    modifyMVar freeSlotList $ \ freeList -> case freeList of
        (s:ss) -> return (ss, s)
        []     -> do        -- free list is empty, we double it

            blockTable <- readIORef blockTableRef
            let oldSiz = sizeofArr blockTable
                newSiz = oldSiz * 2

            blockTable' <- newArr newSiz
            copyArr blockTable' 0 blockTable 0 oldSiz

            forM_ [oldSiz..newSiz-1] $ \ i ->
                writeArr blockTable' i =<< newEmptyMVar
            !iBlockTable' <- unsafeFreezeArr blockTable'

            writeIORef blockTableRef iBlockTable'

            hs_loop_resize loop (fromIntegral newSiz)

            return ([oldSiz+1..newSiz-1], oldSiz)    -- fill the free slot list

freeSlot :: Int -> UVManager -> IO ()
freeSlot slot  (UVManager _ freeSlotList _ _ _ _ _) =
    modifyMVar_ freeSlotList $ \ freeList -> return (slot:freeList)
