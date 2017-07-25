{-# LANGUAGE BangPatterns #-}

{-|
Module      : System.IO.UVManager
Description : I/O manager based on libuv
Copyright   : (c) Winterland, 2017
License     : BSD
Maintainer  : drkoster@qq.com
Stability   : experimental
Portability : non-portable

This module provide I/O manager which bridge libuv's async interface with ghc's light weight thread.

-}

module System.IO.UVManager where

import System.IO.UV
import Data.Array
import Data.Primitive.PrimArray
import Data.Word
import Data.IORef
import Foreign
import Foreign.C
import Control.Concurrent.MVar
import Control.Concurrent
import Control.Monad
import Data.Primitive.Addr
import System.IO.Unsafe

--------------------------------------------------------------------------------

-- | This is data structure attach to uv_loop_t 's data field. It should be mirrored
-- to c struct in hs_uv.c.
--
data UVLoopData = UVLoopData
    { uVLoopEventCounter :: CSize                       -- These two fields compose a special data structure
    , uvLoopEventQueue   :: Ptr CSize                   -- to keep trace of events during a uv_run
                                                        -- before each uv_run the counter should be cleared
                                                        --
    , uvLoopReadBufferTable  :: Ptr (Ptr Word8)         -- a list to keep read buffer's refrerence
    , uvLoopReadBufferSizeTable :: Ptr CSize            -- a list to keep read buffer's size
    , uvLoopWriteBufferTable  :: Ptr (Ptr Word8)        -- a list to keep write buffer's refrerence
    , uvLoopWriteBufferSizeTable  :: Ptr CSize          -- a list to keep write buffer's size
    , uvLoopResultTable  :: Ptr CSize                   -- a list to keep callback's return value
                                                        -- such as file or read bytes number
    }

peekUVLoopuEvent :: Ptr UVLoopData -> IO (Int, Ptr Int)
peekUVLoopuEvent p = do
    let pp = castPtr p
    c <- peek pp :: IO CSize
    q <- peek (pp `plusPtr` 1) :: IO (Ptr a)
    return (fromIntegral c, q)

peekResultTable :: Ptr UVLoopData -> IO (Ptr CSize)
peekResultTable p = do
    let pp = castPtr p
    peek (pp `plusPtr` 6)

peekReadBuffer :: Ptr UVLoopData -> IO (Ptr (Ptr Word8), Ptr CSize)
peekReadBuffer p = do
    let pp = castPtr p
    b <- peek (pp `plusPtr` 2) :: IO (Ptr a)
    s <- peek (pp `plusPtr` 3) :: IO (Ptr a)
    return (castPtr b, s)


clearUVLoopuEventCounter :: Ptr UVLoopData -> IO ()
clearUVLoopuEventCounter p = let pp = castPtr p in poke pp (0 :: CSize)

instance Storable UVLoopData where
    sizeOf _ = sizeOf (undefined :: Word) * 7
    alignment _ = alignment (undefined :: Word)
    poke p (UVLoopData p1 p2 p3 p4 p5 p6 p7) = do
        let pp = castPtr p
        poke pp p1
        poke (pp `plusPtr` 1) p2
        poke (pp `plusPtr` 2) p3
        poke (pp `plusPtr` 3) p4
        poke (pp `plusPtr` 4) p5
        poke (pp `plusPtr` 5) p6
        poke (pp `plusPtr` 6) p7

    peek p =
        let pp = castPtr p
        in UVLoopData
            <$> peek pp
            <*> peek (pp `plusPtr` 1)
            <*> peek (pp `plusPtr` 2)
            <*> peek (pp `plusPtr` 3)
            <*> peek (pp `plusPtr` 4)
            <*> peek (pp `plusPtr` 5)
            <*> peek (pp `plusPtr` 6)

--------------------------------------------------------------------------------

data UVManager = UVManager
    { uvmBlockTable  :: IORef (Array (MVar ()))     -- a list to store blocked thread

    , uvmFreeSlotList :: MVar [Int]                 -- we generate an unique range limited 'Int' /slot/
                                                    -- for each uv_handle_t and uv_req_t

                                                    -- the slot is attached as the data field of
                                                    -- c struct such as handle and request,
                                                    -- thus it will be available to c callback
                                                    -- inside callback we increase event counter and
                                                    -- push slot into event queue
                                                    --
                                                    -- after uv_run is finished, we read the counter
                                                    -- and the queue back, use the slots in the queue
                                                    -- as index to unblock thread in block queue
                                                    --
                                                    -- during uv_run this lock shall be held!
                                                    --
                                                    -- We also use this 'MVar' to do finalization of
                                                    -- I/O manager by attaching finalizers to it with 'mkWeakMVar'


    , uvmLoopData    :: Ptr UVLoopData              -- This is the pointer we pass to uv_loop_t as
                                                    -- data field, it contains above fields
                                                    --
                                                    -- freed when free slot list run out of scope

    , uvmLoop        :: Ptr UVLoop                  -- the uv loop refrerence
                                                    --
                                                    -- close and freed when free slot list run out of scope
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

newUVManager :: Int -> Int -> IO UVManager
newUVManager siz cap = do

    blockTable <- newArr siz
    forM_ [0..siz-1] $ \ i ->
        writeArr blockTable i =<< newEmptyMVar
    iBlockTable <- unsafeFreezeArr blockTable
    iBlockTableRef <- newIORef iBlockTable

    freeSlotList <- newMVar [0..siz-1]

    readBufferTable <- mallocBytes siz'
    readBufferSizeTable <- mallocBytes siz''
    writeBufferTable <- mallocBytes siz'
    writeBufferSizeTable <- mallocBytes siz''
    resultTable <- mallocBytes siz''

    eventQueue <- mallocBytes siz''

    uvLoop <- malloc
    uvLoopData <- malloc

    poke uvLoopData (UVLoopData 0
        eventQueue readBufferTable readBufferSizeTable
        writeBufferTable writeBufferSizeTable resultTable)
    poke uvLoop (UVLoop uvLoopData)

    uv_loop_init uvLoop

    forkOn cap . forever $ do
        withMVar freeSlotList $ \ _ -> do             -- now let's begin
            clearUVLoopuEventCounter uvLoopData
            r <- uv_run uvLoop uV_RUN_NOWAIT
            -- TODO, handle exception
            (c, q) <- peekUVLoopuEvent uvLoopData

            blockTable <- readIORef iBlockTableRef
            forM_ [0..c-1] $ \ i -> do
                slot <- peekElemOff q i
                lock <- indexArrM blockTable slot
                tryPutMVar lock ()
        threadDelay 100
        yield

    _ <- mkWeakMVar freeSlotList $ do
        free readBufferTable
        free readBufferSizeTable
        free writeBufferTable
        free writeBufferSizeTable
        free resultTable
        free eventQueue
        free uvLoopData
        uv_loop_close uvLoop
        free uvLoop

    return (UVManager iBlockTableRef freeSlotList uvLoopData uvLoop)

  where
    siz' = siz * sizeOf (undefined :: Ptr ())
    siz'' = siz * sizeOf (undefined :: CSize)

allocSlot :: UVManager -> IO Int
allocSlot (UVManager blockTableRef freeSlotList uvLoopData uvLoop) = do
    modifyMVar freeSlotList $ \ freeList -> case freeList of
        (s:ss) -> return (ss, s)
        []     -> do        -- free list is empty, we double it
            (UVLoopData eventCounter eventQueue readBufferTable readBufferSizeTable
                writeBufferTable writeBufferSizeTable resultTable) <- peek uvLoopData  -- peek old data back

            blockTable <- readIORef blockTableRef
            let oldSiz = sizeofArr blockTable
                siz = oldSiz * 2
                siz' = siz * sizeOf (undefined :: Ptr ())
                siz'' = siz * sizeOf (undefined :: CSize)

            blockTable' <- newArr siz
            copyArr blockTable' 0 blockTable 0 oldSiz
            forM_ [oldSiz..siz-1] $ \ i ->
                writeArr blockTable' i =<< newEmptyMVar
            !iBlockTable' <- unsafeFreezeArr blockTable'
            writeIORef blockTableRef iBlockTable'

            readBufferTable' <- reallocBytes readBufferTable siz'
            readBufferSizeTable' <- reallocBytes readBufferSizeTable siz''
            writeBufferTable' <- reallocBytes writeBufferTable siz'
            writeBufferSizeTable' <- reallocBytes writeBufferSizeTable siz''
            resultTable' <- reallocBytes resultTable siz''

            eventQueue' <- reallocBytes eventQueue siz''

            poke uvLoopData $ UVLoopData eventCounter
                eventQueue' readBufferTable' readBufferSizeTable'
                writeBufferTable' writeBufferSizeTable' resultTable'

            return ([oldSiz+1..siz-1], oldSiz)    -- fill the free slot list

freeSlot :: Int -> UVManager -> IO ()
freeSlot slot  (UVManager _ freeSlotList _ _) =
    modifyMVar_ freeSlotList $ \ freeList -> return (slot:freeList)


