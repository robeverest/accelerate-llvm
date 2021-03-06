{-# LANGUAGE BangPatterns         #-}
{-# LANGUAGE CPP                  #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE TypeSynonymInstances #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX
-- Copyright   : [2014..2017] Trevor L. McDonell
--               [2014..2014] Vinod Grover (NVIDIA Corporation)
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--
-- This module implements a backend for the /Accelerate/ language targeting
-- NVPTX for execution on NVIDIA GPUs. Expressions are on-line translated into
-- LLVM code, which is just-in-time executed in parallel on the GPU.
--

module Data.Array.Accelerate.LLVM.PTX (

  Acc, Arrays,

  -- * Synchronous execution
  run, runWith,
  run1, run1With,
  runN, runNWith,
  stream, streamWith,

  -- * Asynchronous execution
  Async,
  wait, poll, cancel,

  runAsync, runAsyncWith,
  run1Async, run1AsyncWith,
  runNAsync, runNAsyncWith,

  -- * Execution targets
  PTX, createTargetForDevice, createTargetFromContext,

  -- * Controlling host-side allocation
  registerPinnedAllocator, registerPinnedAllocatorWith,

) where

-- accelerate
import Data.Array.Accelerate.AST                                    ( PreOpenAfun(..) )
import Data.Array.Accelerate.Array.Sugar                            ( Arrays )
import Data.Array.Accelerate.Async
import Data.Array.Accelerate.Debug                                  as Debug
import Data.Array.Accelerate.Error
import Data.Array.Accelerate.Smart                                  ( Acc )
import Data.Array.Accelerate.Trafo

import Data.Array.Accelerate.LLVM.Execute.Async                     ( AsyncR(..) )
import Data.Array.Accelerate.LLVM.Execute.Environment               ( AvalR(..) )
import Data.Array.Accelerate.LLVM.PTX.Compile
import Data.Array.Accelerate.LLVM.PTX.Execute
import Data.Array.Accelerate.LLVM.PTX.Execute.Environment           ( Aval )
import Data.Array.Accelerate.LLVM.PTX.State
import Data.Array.Accelerate.LLVM.PTX.Target
import Data.Array.Accelerate.LLVM.State
import qualified Data.Array.Accelerate.LLVM.PTX.Array.Data          as AD
import qualified Data.Array.Accelerate.LLVM.PTX.Context             as CT
import qualified Data.Array.Accelerate.LLVM.PTX.Execute.Async       as E

import Foreign.CUDA.Driver                                          as CUDA ( CUDAException, mallocHostForeignPtr )

-- standard library
import Control.Exception
import Control.Monad.Trans
import System.IO.Unsafe
import Text.Printf


-- Accelerate: LLVM backend for NVIDIA GPUs
-- ----------------------------------------

-- | Compile and run a complete embedded array program.
--
-- Note that it is recommended that you use 'run1' whenever possible.
--
run :: Arrays a => Acc a -> a
run = runWith defaultTarget

-- | As 'run', but execute using the specified target rather than using the
-- default, automatically selected device.
--
-- Contexts passed to this function may all target to the same device, or to
-- separate devices of differing compute capabilities.
--
runWith :: Arrays a => PTX -> Acc a -> a
runWith target a
  = unsafePerformIO
  $ wait =<< runAsyncWith target a


-- | As 'run', but run the computation asynchronously and return immediately
-- without waiting for the result. The status of the computation can be queried
-- using 'wait', 'poll', and 'cancel'.
--
-- Note that a CUDA context can be active on only one host thread at a time. If
-- you want to execute multiple computations in parallel, on the same or
-- different devices, use 'runAsyncWith'.
--
runAsync :: Arrays a => Acc a -> IO (Async a)
runAsync = runAsyncWith defaultTarget

-- | As 'runWith', but execute asynchronously. Be sure not to destroy the context,
-- or attempt to attach it to a different host thread, before all outstanding
-- operations have completed.
--
runAsyncWith :: Arrays a => PTX -> Acc a -> IO (Async a)
runAsyncWith target a = asyncBound execute
  where
    !acc        = convertAccWith config a
    execute     = do
      dumpGraph acc
      evalPTX target $ do
        acc `seq` dumpSimplStats
        exec <- phase "compile" (compileAcc acc)
        res  <- phase "execute" (executeAcc exec >>= AD.copyToHostLazy)
        return res


-- | This is 'runN', specialised to an array program of one argument.
--
{-# INLINE run1 #-}
run1 :: (Arrays a, Arrays b) => (Acc a -> Acc b) -> a -> b
run1 = run1With defaultTarget

-- | As 'run1', but execute using the specified target rather than using the
-- default, automatically selected device.
--
{-# INLINE run1With #-}
run1With :: (Arrays a, Arrays b) => PTX -> (Acc a -> Acc b) -> a -> b
run1With = runNWith


-- | Prepare and execute an embedded array program.
--
-- This function can be used to improve performance in cases where the array
-- program is constant between invocations, because it enables us to bypass
-- front-end conversion stages and move directly to the execution phase. If you
-- have a computation applied repeatedly to different input data, use this,
-- specifying any changing aspects of the computation via the input parameters.
-- If the function is only evaluated once, this is equivalent to 'run'.
--
-- In order to use 'runN' you must express your Accelerate program as a function
-- of array terms:
--
-- > f :: (Arrays a, Arrays b, ... Arrays c) => Acc a -> Acc b -> ... -> Acc c
--
-- This function then returns the compiled version of 'f':
--
-- > runN f :: (Arrays a, Arrays b, ... Arrays c) => a -> b -> ... -> c
--
-- At an example, rather than:
--
-- > step :: Acc (Vector a) -> Acc (Vector b)
-- > step = ...
-- >
-- > simulate :: Vector a -> Vector b
-- > simulate xs = run $ step (use xs)
--
-- Instead write:
--
-- > simulate = runN step
--
-- You can use the debugging options to check whether this is working
-- successfully. For example, running with the @-ddump-phases@ flag should show
-- that the compilation steps only happen once, not on the second and subsequent
-- invocations of 'simulate'. Note that this typically relies on GHC knowing
-- that it can lift out the function returned by 'runN' and reuse it.
--
-- See the programs in the 'accelerate-examples' package for examples.
--
{-# INLINE runN #-}
runN :: Afunction f => f -> AfunctionR f
runN = runNWith defaultTarget

-- | As 'runN', but execute using the specified target device.
--
{-# INLINE runNWith #-}
runNWith :: Afunction f => PTX -> f -> AfunctionR f
runNWith target f = exec
  where
    !acc  = convertAfunWith config f
    !afun = unsafePerformIO $ do
              dumpGraph acc
              phase "compile" (evalPTX target (compileAfun acc)) >>= dumpStats
    !exec = go afun (return Aempty)

    go :: ExecOpenAfun PTX aenv t -> LLVM PTX (Aval aenv) -> t
    go (Alam l) k = \arrs ->
      let k' = do aenv       <- k
                  AsyncR _ a <- E.async (AD.useRemoteAsync arrs)
                  return (aenv `Apush` a)
      in go l k'
    go (Abody b) k = unsafePerformIO . phase "execute" . evalPTX target $ do
      aenv <- k
      r    <- E.async (executeOpenAcc b aenv)
      AD.copyToHostLazy =<< E.get r


-- | As 'run1', but the computation is executed asynchronously.
--
run1Async :: (Arrays a, Arrays b) => (Acc a -> Acc b) -> a -> IO (Async b)
run1Async = run1AsyncWith defaultTarget

-- | As 'run1With', but execute asynchronously.
--
run1AsyncWith :: (Arrays a, Arrays b) => PTX -> (Acc a -> Acc b) -> a -> IO (Async b)
run1AsyncWith = runNAsyncWith


-- | As 'runN', but execute asynchronously.
--
runNAsync :: (Afunction f, RunAsync r, AfunctionR f ~ RunAsyncR r) => f -> r
runNAsync = runNAsyncWith defaultTarget

-- | As 'runNWith', but execute asynchronously.
--
runNAsyncWith :: (Afunction f, RunAsync r, AfunctionR f ~ RunAsyncR r) => PTX -> f -> r
runNAsyncWith target f = runAsync' target afun (return Aempty)
  where
    !acc  = convertAfunWith config f
    !afun = unsafePerformIO $ do
              dumpGraph acc
              phase "compile" (evalPTX target (compileAfun acc)) >>= dumpStats


class RunAsync f where
  type RunAsyncR f
  runAsync' :: PTX -> ExecOpenAfun PTX aenv (RunAsyncR f) -> LLVM PTX (Aval aenv) -> f

instance RunAsync b => RunAsync (a -> b) where
  type RunAsyncR (a -> b) = a -> RunAsyncR b
  runAsync' _      Abody{}  _ _    = error "runAsync: function oversaturated"
  runAsync' target (Alam l) k arrs =
    let k' = do aenv       <- k
                AsyncR _ a <- E.async (AD.useRemoteAsync arrs)
                return (aenv `Apush` a)
    in runAsync' target l k'

instance RunAsync (IO (Async b)) where
  type RunAsyncR  (IO (Async b)) = b
  runAsync' _      Alam{}    _ = error "runAsync: function not fully applied"
  runAsync' target (Abody b) k = asyncBound . phase "execute" . evalPTX target $ do
    aenv <- k
    r    <- E.async (executeOpenAcc b aenv)
    AD.copyToHostLazy =<< E.get r


-- | Stream a lazily read list of input arrays through the given program,
-- collecting results as we go.
--
stream :: (Arrays a, Arrays b) => (Acc a -> Acc b) -> [a] -> [b]
stream = streamWith defaultTarget

-- | As 'stream', but execute using the specified target.
--
streamWith :: (Arrays a, Arrays b) => PTX -> (Acc a -> Acc b) -> [a] -> [b]
streamWith target f arrs = map go arrs
  where
    !go = run1With target f


-- How the Accelerate program should be evaluated.
--
-- TODO: make sharing/fusion runtime configurable via debug flags or otherwise.
--
config :: Phase
config =  phases
  { convertOffsetOfSegment = True
  }


-- Controlling host-side allocation
-- --------------------------------

-- | Configure the default execution target to allocate all future host-side
-- arrays using (CUDA) pinned memory. Any newly allocated arrays will be
-- page-locked and directly accessible from the device, enabling high-speed
-- (asynchronous) DMA.
--
-- Note that since the amount of available pageable memory will be reduced,
-- overall system performance can suffer.
--
registerPinnedAllocator :: IO ()
registerPinnedAllocator = registerPinnedAllocatorWith defaultTarget


-- | As with 'registerPinnedAllocator', but configure the given execution
-- context.
--
registerPinnedAllocatorWith :: PTX -> IO ()
registerPinnedAllocatorWith target =
  AD.registerForeignPtrAllocator $ \bytes ->
    CT.withContext (ptxContext target) (CUDA.mallocHostForeignPtr [] bytes)
    `catch`
    \e -> $internalError "registerPinnedAlocator" (show (e :: CUDAException))


-- Debugging
-- =========

dumpStats :: MonadIO m => a -> m a
dumpStats x = dumpSimplStats >> return x

phase :: MonadIO m => String -> m a -> m a
phase n go = timed dump_phases (\wall cpu -> printf "phase %s: %s" n (elapsed wall cpu)) go

