{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TupleSections     #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.PTX.Compile.Libdevice.Load
-- Copyright   : [2014..2017] Trevor L. McDonell
--               [2014..2014] Vinod Grover (NVIDIA Corporation)
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@cse.unsw.edu.au>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.PTX.Compile.Libdevice.Load (

  nvvmReflect, libdevice,

) where

-- llvm-hs
import LLVM.Context
import LLVM.Module                                                  as LLVM
import LLVM.AST                                                     as AST ( Module(..), Definition(..) )
import LLVM.AST.Attribute
import LLVM.AST.Global                                              as G
import qualified LLVM.AST.Name                                      as AST

-- accelerate
import LLVM.AST.Type.Name                                           ( Label(..) )
import LLVM.AST.Type.Representation

import Data.Array.Accelerate.Error
import Data.Array.Accelerate.LLVM.CodeGen.Base
import Data.Array.Accelerate.LLVM.CodeGen.Downcast
import Data.Array.Accelerate.LLVM.CodeGen.Intrinsic
import Data.Array.Accelerate.LLVM.PTX.Target

-- cuda
import Foreign.CUDA.Analysis

-- standard library
import Control.Monad.Except
import Data.ByteString                                              ( ByteString )
import Data.HashMap.Strict                                          ( HashMap )
import Data.List
import Data.Maybe
import System.Directory
import System.FilePath
import System.IO.Unsafe
import Text.Printf
import qualified Data.ByteString                                    as B
import qualified Data.ByteString.Char8                              as B8
import qualified Data.HashMap.Strict                                as HashMap


-- NVVM Reflect
-- ------------

class NVVMReflect a where
  nvvmReflect :: a

instance NVVMReflect AST.Module where
  nvvmReflect = nvvmReflectPass_mdl

instance NVVMReflect (String, ByteString) where
  nvvmReflect = nvvmReflectPass_bc


-- This is a hacky module that can be linked against in order to provide the
-- same functionality as running the NVVMReflect pass.
--
-- Note: [NVVM Reflect Pass]
--
-- To accommodate various math-related compiler flags that can affect code
-- generation of libdevice code, the library code depends on a special LLVM IR
-- pass (NVVMReflect) to handle conditional compilation within LLVM IR. This
-- pass looks for calls to the @__nvvm_reflect function and replaces them with
-- constants based on the defined reflection parameters.
--
-- libdevice currently uses the following reflection parameters to control code
-- generation:
--
--   * __CUDA_FTZ={0,1}     fast math that flushes denormals to zero
--
-- Since this is currently the only reflection parameter supported, and that we
-- prefer correct results over pure speed, we do not flush denormals to zero. If
-- the list of supported parameters ever changes, we may need to re-evaluate
-- this implementation.
--
nvvmReflectPass_mdl :: AST.Module
nvvmReflectPass_mdl =
  AST.Module
    { moduleName            = "nvvm-reflect"
    , moduleSourceFileName  = []
    , moduleDataLayout      = targetDataLayout (undefined::PTX)
    , moduleTargetTriple    = targetTriple (undefined::PTX)
    , moduleDefinitions     = [GlobalDefinition $ functionDefaults
      { name                  = AST.Name "__nvvm_reflect"
      , returnType            = downcast (integralType :: IntegralType Int32)
      , parameters            = ( [ptrParameter scalarType (UnName 0 :: Name (Ptr Int8))], False )
      , G.functionAttributes  = map Right [NoUnwind, ReadNone, AlwaysInline]
      , basicBlocks           = []
      }]
    }

{-# NOINLINE nvvmReflectPass_bc #-}
nvvmReflectPass_bc :: (String, ByteString)
nvvmReflectPass_bc = (name,) . unsafePerformIO $ do
  withContext $ \ctx -> do
    runError  $ withModuleFromAST ctx nvvmReflectPass_mdl (return . B8.pack <=< moduleLLVMAssembly)
  where
    name     = "__nvvm_reflect"
    runError = either ($internalError "nvvmReflectPass") return <=< runExceptT


-- libdevice
-- ---------

-- Compatible version of libdevice for a given compute capability should be
-- listed here:
--
--   https://github.com/llvm-mirror/llvm/blob/master/lib/Target/NVPTX/NVPTX.td#L72
--
class Libdevice a where
  libdevice :: Compute -> a

instance Libdevice AST.Module where
  libdevice (Compute n m) =
    case (n,m) of
      (2,_)             -> libdevice_20_mdl   -- 2.0, 2.1
      (3,x) | x < 5     -> libdevice_30_mdl   -- 3.0, 3.2
            | otherwise -> libdevice_35_mdl   -- 3.5, 3.7
      (5,_)             -> libdevice_50_mdl   -- 5.x
      (6,_)             -> libdevice_50_mdl   -- 6.x
      _                 -> $internalError "libdevice" "no binary for this architecture"

instance Libdevice (String, ByteString) where
  libdevice (Compute n m) =
    case (n,m) of
      (2,_)             -> libdevice_20_bc    -- 2.0, 2.1
      (3,x) | x < 5     -> libdevice_30_bc    -- 3.0, 3.2
            | otherwise -> libdevice_35_bc    -- 3.5, 3.7
      (5,_)             -> libdevice_50_bc    -- 5.x
      (6,_)             -> libdevice_50_bc    -- 6.x
      _                 -> $internalError "libdevice" "no binary for this architecture"


-- Load the libdevice bitcode files as an LLVM AST module. The top-level
-- unsafePerformIO ensures that the data is only read from disk once per program
-- execution.
--
{-# NOINLINE libdevice_20_mdl #-}
{-# NOINLINE libdevice_30_mdl #-}
{-# NOINLINE libdevice_35_mdl #-}
{-# NOINLINE libdevice_50_mdl #-}
libdevice_20_mdl, libdevice_30_mdl, libdevice_35_mdl, libdevice_50_mdl :: AST.Module
libdevice_20_mdl = unsafePerformIO $ libdeviceModule (Compute 2 0)
libdevice_30_mdl = unsafePerformIO $ libdeviceModule (Compute 3 0)
libdevice_35_mdl = unsafePerformIO $ libdeviceModule (Compute 3 5)
libdevice_50_mdl = unsafePerformIO $ libdeviceModule (Compute 5 0)

-- Load the libdevice bitcode files as raw binary data. The top-level
-- unsafePerformIO ensures that the data is read only once per program
-- execution.
--
{-# NOINLINE libdevice_20_bc #-}
{-# NOINLINE libdevice_30_bc #-}
{-# NOINLINE libdevice_35_bc #-}
{-# NOINLINE libdevice_50_bc #-}
libdevice_20_bc, libdevice_30_bc, libdevice_35_bc, libdevice_50_bc :: (String,ByteString)
libdevice_20_bc = unsafePerformIO $ libdeviceBitcode (Compute 2 0)
libdevice_30_bc = unsafePerformIO $ libdeviceBitcode (Compute 3 0)
libdevice_35_bc = unsafePerformIO $ libdeviceBitcode (Compute 3 5)
libdevice_50_bc = unsafePerformIO $ libdeviceBitcode (Compute 5 0)


-- Load the libdevice bitcode file for the given compute architecture, and raise
-- it to a Haskell AST that can be kept for future use. The name of the bitcode
-- files follows:
--
--   libdevice.compute_XX.YY.bc
--
-- Where XX represents the compute capability, and YY represents a version(?) We
-- search the libdevice PATH for all files of the appropriate compute capability
-- and load the most recent.
--
libdeviceModule :: Compute -> IO AST.Module
libdeviceModule arch = do
  let bc :: (String, ByteString)
      bc = libdevice arch

  -- TLM: we have called 'withContext' again here, although the LLVM state
  --      already carries a version of the context. We do this so that we can
  --      fully apply this function that can be lifted out to a CAF and only
  --      executed once per program execution.
  --
  withContext $ \ctx ->
    either ($internalError "libdeviceModule") id `fmap`
    runExceptT (withModuleFromBitcode ctx bc moduleAST)


-- Load the libdevice bitcode file for the given compute architecture. The name
-- of the bitcode files follows the format:
--
--   libdevice.compute_XX.YY.bc
--
-- Where XX represents the compute capability, and YY represents a version(?) We
-- search the libdevice PATH for all files of the appropriate compute capability
-- and load the "most recent" (by sort order).
--
libdeviceBitcode :: Compute -> IO (String, ByteString)
libdeviceBitcode (Compute m n) = do
  let arch       = printf "libdevice.compute_%d%d" m n
      err        = $internalError "libdevice" (printf "not found: %s.YY.bc" arch)
      best f     = arch `isPrefixOf` f && takeExtension f == ".bc"

  path  <- libdevicePath
  files <- getDirectoryContents path
  name  <- maybe err return . listToMaybe . sortBy (flip compare) $ filter best files
  bc    <- B.readFile (path </> name)

  return (name, bc)


-- Determine the location of the libdevice bitcode libraries. We search for the
-- location of the 'nvcc' executable in the PATH. From that, we assume the
-- location of the libdevice bitcode files.
--
libdevicePath :: IO FilePath
libdevicePath = do
  nvcc  <- fromMaybe (error "could not find 'nvcc' in PATH") `fmap` findExecutable "nvcc"

  let ccvn = reverse (splitPath nvcc)
      dir  = "libdevice" : "nvvm" : drop 2 ccvn

  return (joinPath (reverse dir))

