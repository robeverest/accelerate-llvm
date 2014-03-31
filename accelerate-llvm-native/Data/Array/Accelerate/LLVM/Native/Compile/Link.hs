{-# LANGUAGE CPP             #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections   #-}
-- |
-- Module      : Data.Array.Accelerate.LLVM.Native.Compile.Link
-- Copyright   : [2014] Trevor L. McDonell, Sean Lee, Vinod Grover
-- License     : BSD3
--
-- Maintainer  : Trevor L. McDonell <tmcdonell@nvidia.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module Data.Array.Accelerate.LLVM.Native.Compile.Link
  where

-- llvm-general
import LLVM.General.AST
import LLVM.General.AST.Global

import LLVM.General.ExecutionEngine

-- standard library
import Data.Maybe

#include "accelerate.h"


-- | Return function pointers to all of the global function definitions in the
-- given executable module.
--
getGlobalFunctions
    :: ExecutionEngine e f
    => Module
    -> ExecutableModule e
    -> IO [(String, f)]
getGlobalFunctions ast exe
  = mapM (\f -> (f,) `fmap` link f)
  $ globalFunctions (moduleDefinitions ast)
  where
    link f = fromMaybe (INTERNAL_ERROR(error) "link" "function not found") `fmap` getFunction exe (Name f)


-- | Extract the names of the function definitions from a module
--
-- TLM: move this somewhere it can be shared between Native/NVVM backend
--
globalFunctions :: [Definition] -> [String]
globalFunctions defs =
  [ n | GlobalDefinition Function{..} <- defs
      , not (null basicBlocks)
      , let Name n = name
      ]

