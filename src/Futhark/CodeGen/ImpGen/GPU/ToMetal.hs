{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}

-- | This module defines a translation from imperative code with
-- kernels to imperative code with Metal calls.
module Futhark.CodeGen.ImpGen.GPU.ToMetal (kernelsToMetal)
where

import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Futhark.CodeGen.Backends.GenericC as GC
import Futhark.CodeGen.Backends.SimpleRep
import Futhark.CodeGen.ImpCode.GPU hiding (Program)
import qualified Futhark.CodeGen.ImpCode.GPU as ImpGPU
import Futhark.CodeGen.ImpCode.Metal hiding (Program)
import qualified Futhark.CodeGen.ImpCode.Metal as ImpMetal
import Futhark.CodeGen.RTS.C (atomicsH, halfH)
import Futhark.Error (compilerLimitationS)
import Futhark.IR.Prop (isBuiltInFunction)
import Futhark.MonadFreshNames
import Futhark.Util (zEncodeString)
import Futhark.Util.Pretty (prettyOneLine, prettyText)
import qualified Language.C.Quote.OpenCL as C
import qualified Language.C.Syntax as C
import NeatInterpolation (untrimming)



{-
    
    class MetalEngine
    {
      public:
          mtlpp::Device _mDevice = mtlpp::Device::CreateSystemDefaultDevice();

          // The compute pipeline generated from the compute kernel in the .metal shader file.
          mtlpp::ComputePipelineState _mFunctionPSO;

          // The command queue used to pass commands to the device.
          mtlpp::CommandQueue _mCommandQueue;

          // Buffers to hold data.
          mtlpp::Buffer _mBufferA;
          mtlpp::Buffer _mBufferB;
          mtlpp::Buffer _mBufferResult;


      //By Default, Metallib is made at compilation time however this is an 
      //alternative constructor to run const chars as Metal Scripts
      //Possibly more Important for Futhark
      MetalEngine(const char src[], ns::String functionName, mtlpp::Device device){

          _mDevice = device; 

          ns::Error* error = NULL; //nullptr
          mtlpp::Library library  = device.NewLibrary(src, mtlpp::CompileOptions(), error);
          assert(library);
          mtlpp::Function Func = library.NewFunction(functionName);
          assert(Func);

          _mFunctionPSO = device.NewComputePipelineState(Func, error);
          assert(_mFunctionPSO);

          _mCommandQueue = device.NewCommandQueue();
          assert(_mCommandQueue);
      }

      void generateRandomFloatData(mtlpp::Buffer buffer)
      {
          float* dataPtr = (float*)buffer.GetContents();

          for (unsigned long index = 0; index < arrayLength; index++)
          {
              dataPtr[index] = (float)rand()/(float)(RAND_MAX);
          }
      }

      void prepareData(mtlpp::Device device)
      {
          // Allocate three buffers to hold our initial data and the result.
          _mBufferA = device.NewBuffer(bufferSize, mtlpp::ResourceOptions::StorageModeShared);
          _mBufferB = device.NewBuffer(bufferSize, mtlpp::ResourceOptions::StorageModeShared);
          _mBufferResult = device.NewBuffer(bufferSize, mtlpp::ResourceOptions::StorageModeShared);

          generateRandomFloatData(_mBufferA);
          generateRandomFloatData(_mBufferB);
      }

      void sendComputeCommand(mtlpp::CommandQueue commandQueue)
      {
          // Create a command buffer to hold commands.
          mtlpp::CommandBuffer commandBuffer = commandQueue.CommandBuffer();
          // Start a compute pass.
          mtlpp::ComputeCommandEncoder computeEncoder = commandBuffer.ComputeCommandEncoder();// computeCommandEncoder];

          encodeAddCommand(computeEncoder);
          // End the compute pass.
          computeEncoder.EndEncoding();

          // Execute the command.
          commandBuffer.Commit();

          // Normally, you want to do other work in your app while the GPU is running,
          // but in this example, the code simply blocks until the calculation is complete.
          commandBuffer.WaitUntilCompleted();

          verifyResults();
      }


      void encodeAddCommand(mtlpp::ComputeCommandEncoder computeEncoder) {

          // Encode the pipeline state object and its parameters.
          computeEncoder.SetComputePipelineState(_mFunctionPSO);
          computeEncoder.SetBuffer(_mBufferA, 0, 0);
          computeEncoder.SetBuffer(_mBufferB, 0, 1);
          computeEncoder.SetBuffer(_mBufferResult, 0, 2);
          //_mBufferResult offset:x atIndex:y

          mtlpp::Size gridSize = mtlpp::Size(arrayLength, 1, 1);

          // Calculate a threadgroup size.
          uint32_t threadGroupSize = _mFunctionPSO.GetMaxTotalThreadsPerThreadgroup();
          if (threadGroupSize > arrayLength)
          {
              threadGroupSize = arrayLength;
          }
          mtlpp::Size threadgroupSize = mtlpp::Size(threadGroupSize, 1, 1);

          // Encode the compute command.
          computeEncoder.DispatchThreadgroups(gridSize, threadgroupSize);
      }


      void verifyResults()
      {
          float* a = (float*)_mBufferA.GetContents();
          float* b = (float*)_mBufferB.GetContents();
          float* result = (float*)_mBufferResult.GetContents();

          for (unsigned long index = 0; index < arrayLength; index++)
          {
              if (result[index] != (a[index] + b[index]))
              {
                  printf("Compute ERROR: index=%lu result=%g vs %g=a+b\n",
                      index, result[index], a[index] + b[index]);
                  //assert(result[index] == (a[index] + b[index]));
              }
              else{
                    printf("Compute MATCH: index=%lu result=%g vs %g=a+b\n",
                      index, result[index], a[index] + b[index]);
              }
          }
          printf("Compute results as expected\n");
      }
    };

    int main(int argc, char * argv[]){
    mtlpp::Device device = mtlpp::Device::CreateSystemDefaultDevice();

    // Create the custom object used to encapsulate the Metal code.
    // Initializes objects to communicate with the GPU.
    MetalEngine adder = MetalEngine(device);

    // Create buffers to hold data
    adder.prepareData($id:metal_program device);

    // Send a command to the GPU to perform the calculation.
    adder.sendComputeCommand(adder._mCommandQueue);

    printf("Execution finished\n");
    }
-}


kernelsToMetal :: ImpGPU.Program -> ImpMetal.Program
kernelsToMetal = translateGPU TargetMetal

-- | Translate a kernels-program to a Metal-program.
translateGPU ::
  KernelTarget ->
  ImpGPU.Program ->
  ImpMetal.Program
translateGPU target prog =
  let ( prog',
        ToMetal kernels device_funs used_types sizes failures
        ) =
          (`runState` initialMetal) . (`runReaderT` defFuns prog) $ do
            let ImpGPU.Definitions
                  (ImpGPU.Constants ps consts)
                  (ImpGPU.Functions funs) = prog
            consts' <- traverse (onHostOp target) consts
            funs' <- forM funs $ \(fname, fun) ->
              (fname,) <$> traverse (onHostOp target) fun

            return $
              ImpMetal.Definitions
                (ImpMetal.Constants ps consts')
                (ImpMetal.Functions funs')

      (device_prototypes, device_defs) = unzip $ M.elems device_funs
      kernels' = M.map fst kernels
      metal_code = metalCode $ map snd $ M.elems kernels

      metal_prelude =
        T.unlines
          [ genPrelude target used_types,
            T.unlines $ map prettyText device_prototypes,
            T.unlines $ map prettyText device_defs
          ]
   in ImpMetal.Program
        metal_code
        metal_prelude
        kernels'
        (S.toList used_types)
        (cleanSizes sizes)
        failures
        prog'
  where
    genPrelude TargetMetal = const genMetalPrelude

-- | Due to simplifications after kernel extraction, some threshold
-- parameters may contain KernelPaths that reference threshold
-- parameters that no longer exist.  We remove these here.
cleanSizes :: M.Map Name SizeClass -> M.Map Name SizeClass
cleanSizes m = M.map clean m
  where
    known = M.keys m
    clean (SizeThreshold path def) =
      SizeThreshold (filter ((`elem` known) . fst) path) def
    clean s = s

pointerQuals :: Monad m => String -> m [C.TypeQual]
pointerQuals "global" = return [C.ctyquals|__global|]
pointerQuals "local" = return [C.ctyquals|__local|]
pointerQuals "private" = return [C.ctyquals|__private|]
pointerQuals "constant" = return [C.ctyquals|__constant|]
pointerQuals "write_only" = return [C.ctyquals|__write_only|]
pointerQuals "read_only" = return [C.ctyquals|__read_only|]
pointerQuals "kernel" = return [C.ctyquals|__kernel|]
pointerQuals s = error $ "'" ++ s ++ "' is not an Metal kernel address space."

-- In-kernel name and per-workgroup size in bytes.
type LocalMemoryUse = (VName, Count Bytes Exp)

data KernelState = KernelState
  { kernelLocalMemory :: [LocalMemoryUse],
    kernelFailures :: [FailureMsg],
    kernelNextSync :: Int,
    -- | Has a potential failure occurred sine the last
    -- ErrorSync?
    kernelSyncPending :: Bool,
    kernelHasBarriers :: Bool
  }

newKernelState :: [FailureMsg] -> KernelState
newKernelState failures = KernelState mempty failures 0 False False

errorLabel :: KernelState -> String
errorLabel = ("error_" ++) . show . kernelNextSync

data ToMetal = ToMetal
  { mGPU :: M.Map KernelName (KernelSafety, C.Func),
    mDevFuns :: M.Map Name (C.Definition, C.Func),
    mUsedTypes :: S.Set PrimType,
    mSizes :: M.Map Name SizeClass,
    mFailures :: [FailureMsg]
  }

initialMetal :: ToMetal
initialMetal = ToMetal mempty mempty mempty mempty mempty

type AllFunctions = ImpGPU.Functions ImpGPU.HostOp

lookupFunction :: Name -> AllFunctions -> Maybe ImpGPU.Function
lookupFunction fname (ImpGPU.Functions fs) = lookup fname fs

type OnKernelM = ReaderT AllFunctions (State ToMetal)

addSize :: Name -> SizeClass -> OnKernelM ()
addSize key sclass =
  modify $ \s -> s {mSizes = M.insert key sclass $ mSizes s}

onHostOp :: KernelTarget -> HostOp -> OnKernelM Metal
onHostOp target (CallKernel k) = onKernel target k
onHostOp _ (ImpGPU.GetSize v key size_class) = do
  addSize key size_class          --uint32_t threadGroupSize = _mAddFunctionPSO.GetMaxTotalThreadsPerThreadgroup();
  return $ ImpMetal.GetSize v key --mtlpp::Size threadgroupSize = mtlpp::Size(threadGroupSize, 1, 1);
onHostOp _ (ImpGPU.CmpSizeLe v key size_class x) = do
  addSize key size_class
  return $ ImpMetal.CmpSizeLe v key x
onHostOp _ (ImpGPU.GetSizeMax v size_class) =
  return $ ImpMetal.GetSizeMax v size_class

genGPUCode ::
  OpsMode ->
  KernelCode ->
  [FailureMsg] ->
  GC.CompilerM KernelOp KernelState a ->
  (a, GC.CompilerState KernelState)
genGPUCode mode body failures =
  GC.runCompilerM
    (inKernelOperations mode body)
    blankNameSource
    (newKernelState failures)

-- Compilation of a device function that is not not invoked from the
-- host, but is invoked by (perhaps multiple) kernels.
generateDeviceFun :: Name -> ImpGPU.Function -> OnKernelM ()
generateDeviceFun fname host_func = do
  -- Functions are a priori always considered host-level, so we have
  -- to convert them to device code.  This is where most of our
  -- limitations on device-side functions (no arrays, no parallelism)
  -- comes from.
  let device_func = fmap toDevice host_func
  when (any memParam $ functionInput host_func) bad

  failures <- gets mFailures

  let params =
        [ [C.cparam|__global int *global_failure|],
          [C.cparam|__global typename int64_t *global_failure_args|]
        ]
      (func, cstate) =
        genGPUCode FunMode (functionBody device_func) failures $
          GC.compileFun mempty params (fname, device_func)
      kstate = GC.compUserState cstate

  modify $ \s ->
    s
      { mUsedTypes = typesInCode (functionBody device_func) <> mUsedTypes s,
        mDevFuns = M.insert fname func $ mDevFuns s,
        mFailures = kernelFailures kstate
      }

  -- Important to do this after the 'modify' call, so we propagate the
  -- right clFailures.
  void $ ensureDeviceFuns $ functionBody device_func
  where
    toDevice :: HostOp -> KernelOp
    toDevice _ = bad

    memParam MemParam {} = True
    memParam ScalarParam {} = False

    bad = compilerLimitationS "Cannot generate GPU functions that use arrays."

-- Ensure that this device function is available, but don't regenerate
-- it if it already exists.
ensureDeviceFun :: Name -> ImpGPU.Function -> OnKernelM ()
ensureDeviceFun fname host_func = do
  exists <- gets $ M.member fname . mDevFuns
  unless exists $ generateDeviceFun fname host_func

ensureDeviceFuns :: ImpGPU.KernelCode -> OnKernelM [Name]
ensureDeviceFuns code = do
  let called = calledFuncs code
  fmap catMaybes $
    forM (S.toList called) $ \fname -> do
      def <- asks $ lookupFunction fname
      case def of
        Just func -> do
          ensureDeviceFun fname func
          return $ Just fname
        Nothing -> return Nothing

onKernel :: KernelTarget -> Kernel -> OnKernelM Metal
onKernel target kernel = do
  called <- ensureDeviceFuns $ kernelBody kernel

  -- Crucial that this is done after 'ensureDeviceFuns', as the device
  -- functions may themselves define failure points.
  failures <- gets mFailures

  let (kernel_body, cstate) =
        genGPUCode KernelMode (kernelBody kernel) failures $
          GC.blockScope $ GC.compileCode $ kernelBody kernel
      kstate = GC.compUserState cstate

      (local_memory_args, local_memory_params, local_memory_init) =
        unzip3 . flip evalState (blankNameSource :: VNameSource) $
          mapM (prepareLocalMemory target) $ kernelLocalMemory kstate

      -- CUDA has very strict restrictions on the number of blocks
      -- permitted along the 'y' and 'z' dimensions of the grid
      -- (1<<16).  To work around this, we are going to dynamically
      -- permute the block dimensions to move the largest one to the
      -- 'x' dimension, which has a higher limit (1<<31).  This means
      -- we need to extend the kernel with extra parameters that
      -- contain information about this permutation, but we only do
      -- this for multidimensional kernels (at the time of this
      -- writing, only transposes).  The corresponding arguments are
      -- added automatically in CCUDA.hs.
      (perm_params, block_dim_init) =
        case (target, num_groups) of
          (TargetMetal, [_, _, _]) ->
            ( [ [C.cparam|const int block_dim0|],
                [C.cparam|const int block_dim1|],
                [C.cparam|const int block_dim2|]
              ],
              mempty
            )
          _ ->
            ( mempty,
              [ [C.citem|const int block_dim0 = 0;|],
                [C.citem|const int block_dim1 = 1;|],
                [C.citem|const int block_dim2 = 2;|]
              ]
            )

      (const_defs, const_undefs) = unzip $ mapMaybe constDef $ kernelUses kernel

  let (use_params, unpack_params) =
        unzip $ mapMaybe useAsParam $ kernelUses kernel

  let (safety, error_init)
        -- We conservatively assume that any called function can fail.
        | not $ null called =
          (SafetyFull, [])
        | length (kernelFailures kstate) == length failures =
          if kernelFailureTolerant kernel
            then (SafetyNone, [])
            else -- No possible failures in this kernel, so if we make
            -- it past an initial check, then we are good to go.

              ( SafetyCheap,
                [C.citems|if (*global_failure >= 0) { return; }|]
              )
        | otherwise =
          if not (kernelHasBarriers kstate)
            then
              ( SafetyFull,
                [C.citems|if (*global_failure >= 0) { return; }|]
              )
            else
              ( SafetyFull,
                [C.citems|
                     volatile __local bool local_failure;
                     if (failure_is_an_option) {
                       int failed = *global_failure >= 0;
                       if (failed) {
                         return;
                       }
                     }
                     // All threads write this value - it looks like CUDA has a compiler bug otherwise.
                     local_failure = false;
                     barrier(CLK_LOCAL_MEM_FENCE);
                  |]
              )

      failure_params =
        [ [C.cparam|__global int *global_failure|],
          [C.cparam|int failure_is_an_option|],
          [C.cparam|__global typename int64_t *global_failure_args|]
        ]

      params =
        perm_params
          ++ take (numFailureParams safety) failure_params
          ++ catMaybes local_memory_params
          ++ use_params

      kernel_fun =
        [C.cfun|__kernel void $id:name ($params:params) {
                  $items:(mconcat unpack_params)
                  $items:const_defs
                  $items:block_dim_init
                  $items:local_memory_init
                  $items:error_init
                  $items:kernel_body

                  $id:(errorLabel kstate): return;

                  $items:const_undefs
                }|]
  modify $ \s ->
    s
      { mGPU = M.insert name (safety, kernel_fun) $ mGPU s,
        mUsedTypes = typesInKernel kernel <> mUsedTypes s,
        mFailures = kernelFailures kstate
      }

  -- The argument corresponding to the global_failure parameters is
  -- added automatically later.
  let args =
        catMaybes local_memory_args
          ++ kernelArgs kernel

  return $ LaunchKernel safety name args num_groups group_size
  where
    name = kernelName kernel
    num_groups = kernelNumGroups kernel
    group_size = kernelGroupSize kernel

    prepareLocalMemory TargetMetal (mem, size) = do
      mem_aligned <- newVName $ baseString mem ++ "_aligned"
      return
        ( Just $ SharedMemoryKArg size,
          Just [C.cparam|__local volatile typename int64_t* $id:mem_aligned|],
          [C.citem|__local volatile unsigned char* restrict $id:mem = (__local volatile unsigned char*) $id:mem_aligned;|]
        )
    prepareLocalMemory TargetMetal (mem, size) = do
      param <- newVName $ baseString mem ++ "_offset"
      return
        ( Just $ SharedMemoryKArg size,
          Just [C.cparam|uint $id:param|],
          [C.citem|volatile $ty:defaultMemBlockType $id:mem = &shared_mem[$id:param];|]
        )

useAsParam :: KernelUse -> Maybe (C.Param, [C.BlockItem])
useAsParam (ScalarUse name pt) = do
  let name_bits = zEncodeString (pretty name) <> "_bits"
      ctp = case pt of
        -- Metal may or may not permit bool as a kernel parameter type.
        Bool -> [C.cty|unsigned char|]
        Unit -> [C.cty|unsigned char|]
        _ -> primStorageType pt
  if ctp == primTypeToCType pt
    then Just ([C.cparam|$ty:ctp $id:name|], [])
    else
      let name_bits_e = [C.cexp|$id:name_bits|]
       in Just
            ( [C.cparam|$ty:ctp $id:name_bits|],
              [[C.citem|$ty:(primTypeToCType pt) $id:name = $exp:(fromStorage pt name_bits_e);|]]
            )
useAsParam (MemoryUse name) =
  Just ([C.cparam|__global $ty:defaultMemBlockType $id:name|], [])
useAsParam ConstUse {} =
  Nothing

-- Constants are #defined as macros.  Since a constant name in one
-- kernel might potentially (although unlikely) also be used for
-- something else in another kernel, we #undef them after the kernel.
constDef :: KernelUse -> Maybe (C.BlockItem, C.BlockItem)
constDef (ConstUse v e) =
  Just
    ( [C.citem|$escstm:def|],
      [C.citem|$escstm:undef|]
    )
  where
    e' = compilePrimExp e
    def = "#define " ++ pretty (C.toIdent v mempty) ++ " (" ++ prettyOneLine e' ++ ")"
    undef = "#undef " ++ pretty (C.toIdent v mempty)
constDef _ = Nothing

metalCode :: [C.Func] -> T.Text
metalCode kernels =
  prettyText [C.cunit|$edecls:funcs|]
  where
    funcs =
      [ [C.cedecl|$func:kernel_func|]
        | kernel_func <- kernels
      ]

genMetalPrelude :: T.Text
genMetalPrelude =
  [untrimming|
#define FUTHARK_METAL
#define FUTHARK_F64_ENABLED

typedef char int8_t;
typedef short int16_t;
typedef int int32_t;
typedef long long int64_t;
typedef unsigned char uint8_t;
typedef unsigned short uint16_t;
typedef unsigned int uint32_t;
typedef unsigned long long uint64_t;
typedef uint8_t uchar;
typedef uint16_t ushort;
typedef uint32_t uint;
typedef uint64_t ulong;
#define __global
#define __local
#define __private
#define __constant
#define __write_only
#define __read_only
#define NAN (0.0/0.0)
#define INFINITY (1.0/0.0)

      class MetalEngine
      {
          public:
              mtlpp::Device _mDevice = mtlpp::Device::CreateSystemDefaultDevice();

              // The compute pipeline generated from the compute kernel in the .metal shader file.
              mtlpp::ComputePipelineState _mFunctionPSO;

              // The command queue used to pass commands to the device.
              mtlpp::CommandQueue _mCommandQueue;

              // Buffers to hold data.
              mtlpp::Buffer _mBufferA;
              mtlpp::Buffer _mBufferB;
              mtlpp::Buffer _mBufferResult;

              //Pointer for Any Errors generated
              ns::Error* error; //nullptr

          //Initializes based on a path
          MetalEngine(ns::String libraryPath, ns::String mtlFunction, mtlpp::Device device)
          {
              _mDevice = device;
              //device.NewDefaultLibrary();
              error = NULL;

              // Load the shader files with a .metal file extension in the project
              // .metallib
              mtlpp::Library defaultLibrary = device.NewLibrary(libraryPath, error);
              if (defaultLibrary.GetFunctionNames() == NULL)
              {
                  printf("Failed to find the default library.\n");
              }
              mtlpp::Function Function = defaultLibrary.NewFunction(mtlFunction);

              // Create a compute pipeline state object.
              _mFunctionPSO = device.NewComputePipelineState(Function, error);
              _mCommandQueue = device.NewCommandQueue();
          }

          MetalEngine(ns::String mtlFunction, mtlpp::Device device)
          {
              _mDevice = device;
              //device.NewDefaultLibrary();
              error = NULL;

              // Load the shader files with a .metal file extension in the project
              // .metallib
              mtlpp::Library defaultLibrary = device.NewDefaultLibrary();
              if (defaultLibrary.GetFunctionNames() == NULL)
              {
                  printf("Failed to find the default library.\n");

              }
              //"mtlAddArrays"
              mtlpp::Function Function = defaultLibrary.NewFunction(mtlFunction);

              // Create a compute pipeline state object.
              _mFunctionPSO = device.NewComputePipelineState(Function, error);
          
              _mCommandQueue = device.NewCommandQueue();
          }

          //By Default, Metallib is made at compilation time however this is an 
          //alternative constructor to run const chars as Metal Scripts
          //Possibly more Important for Futhark
          MetalEngine(const char src[], ns::String functionName, mtlpp::Device device){

              _mDevice = device; 

              error = NULL; //nullptr
              mtlpp::Library library  = device.NewLibrary(src, mtlpp::CompileOptions(), error);
              assert(library);
              mtlpp::Function Func = library.NewFunction(functionName);
              assert(Func);

              _mFunctionPSO = device.NewComputePipelineState(Func, error);
              assert(_mFunctionPSO);

              _mCommandQueue = device.NewCommandQueue();
              assert(_mCommandQueue);
          }

          void generateRandomFloatData(mtlpp::Buffer buffer)
          {
              float* dataPtr = (float*)buffer.GetContents();

              for (unsigned long index = 0; index < arrayLength; index++)
              {
                  dataPtr[index] = (float)rand()/(float)(RAND_MAX);
              }
          }

          void prepareData(mtlpp::Device device)
          {
              // Allocate three buffers to hold our initial data and the result.
              _mBufferA = device.NewBuffer(bufferSize, mtlpp::ResourceOptions::StorageModeShared);
              _mBufferB = device.NewBuffer(bufferSize, mtlpp::ResourceOptions::StorageModeShared);
              _mBufferResult = device.NewBuffer(bufferSize, mtlpp::ResourceOptions::StorageModeShared);

              generateRandomFloatData(_mBufferA);
              generateRandomFloatData(_mBufferB);
          }

          void sendComputeCommand(mtlpp::CommandQueue commandQueue)
          {
              // Create a command buffer to hold commands.
              mtlpp::CommandBuffer commandBuffer = commandQueue.CommandBuffer();
              // Start a compute pass.
              mtlpp::ComputeCommandEncoder computeEncoder = commandBuffer.ComputeCommandEncoder();// computeCommandEncoder];

              encodeAddCommand(computeEncoder);
              // End the compute pass.
              computeEncoder.EndEncoding();

              // Execute the command.
              commandBuffer.Commit();

              // Normally, you want to do other work in your app while the GPU is running,
              // but in this example, the code simply blocks until the calculation is complete.
              commandBuffer.WaitUntilCompleted();

              verifyResults();
          }


          void encodeAddCommand(mtlpp::ComputeCommandEncoder computeEncoder) {

              // Encode the pipeline state object and its parameters.
              computeEncoder.SetComputePipelineState(_mFunctionPSO);
              computeEncoder.SetBuffer(_mBufferA, 0, 0);
              computeEncoder.SetBuffer(_mBufferB, 0, 1);
              computeEncoder.SetBuffer(_mBufferResult, 0, 2);
              //_mBufferResult offset:x atIndex:y

              mtlpp::Size gridSize = mtlpp::Size(arrayLength, 1, 1);

              // Calculate a threadgroup size.
              uint32_t threadGroupSize = _mFunctionPSO.GetMaxTotalThreadsPerThreadgroup();
              if (threadGroupSize > arrayLength)
              {
                  threadGroupSize = arrayLength;
              }
              mtlpp::Size threadgroupSize = mtlpp::Size(threadGroupSize, 1, 1);

              // Encode the compute command.
              computeEncoder.DispatchThreadgroups(gridSize, threadgroupSize);
          }


          void verifyResults()
          {
              float* a = (float*)_mBufferA.GetContents();
              float* b = (float*)_mBufferB.GetContents();
              float* result = (float*)_mBufferResult.GetContents();

              for (unsigned long index = 0; index < arrayLength; index++)
              {
                  if (result[index] != (a[index] + b[index]))
                  {
                      printf("Compute ERROR: index=%lu result=%g vs %g=a+b\n",
                          index, result[index], a[index] + b[index]);
                      //assert(result[index] == (a[index] + b[index]));
                  }
                  else{
                        printf("Compute MATCH: index=%lu result=%g vs %g=a+b\n",
                          index, result[index], a[index] + b[index]);
                  }
              }
              printf("Compute results as expected\n");
          }


          void execute(int argc, const char* argv[]){
            mtlpp::Device device = mtlpp::Device::CreateSystemDefaultDevice();

            // Create the custom object used to encapsulate the Metal code.
            // Initializes objects to communicate with the GPU.
            MetalEngine engine = MetalEngine(device);
            //MetalEngine engineAlt = MetalEngine(argv, device);

            // Create buffers to hold data
            engine.prepareData(device);
            
            // Send a command to the GPU to perform the calculation.
            engine.sendComputeCommand(engine._mCommandQueue);

            printf("Execution finished\n");
          }
      };
|]
    <> halfH
    <> cScalarDefs
    <> atomicsH

compilePrimExp :: PrimExp KernelConst -> C.Exp
compilePrimExp e = runIdentity $ GC.compilePrimExp compileKernelConst e
  where
    compileKernelConst (SizeConst key) =
      return [C.cexp|$id:(zEncodeString (pretty key))|]

kernelArgs :: Kernel -> [KernelArg]
kernelArgs = mapMaybe useToArg . kernelUses
  where
    useToArg (MemoryUse mem) = Just $ MemKArg mem
    useToArg (ScalarUse v pt) = Just $ ValueKArg (LeafExp v pt) pt
    useToArg ConstUse {} = Nothing

nextErrorLabel :: GC.CompilerM KernelOp KernelState String
nextErrorLabel =
  errorLabel <$> GC.getUserState

incErrorLabel :: GC.CompilerM KernelOp KernelState ()
incErrorLabel =
  GC.modifyUserState $ \s -> s {kernelNextSync = kernelNextSync s + 1}

pendingError :: Bool -> GC.CompilerM KernelOp KernelState ()
pendingError b =
  GC.modifyUserState $ \s -> s {kernelSyncPending = b}

hasCommunication :: ImpGPU.KernelCode -> Bool
hasCommunication = any communicates
  where
    communicates ErrorSync {} = True
    communicates Barrier {} = True
    communicates _ = False

-- Whether we are generating code for a kernel or a device function.
-- This has minor effects, such as exactly how failures are
-- propagated.
data OpsMode = KernelMode | FunMode deriving (Eq)

inKernelOperations ::
  OpsMode ->
  ImpGPU.KernelCode ->
  GC.Operations KernelOp KernelState
inKernelOperations mode body =
  GC.Operations
    { GC.opsCompiler = kernelOps,
      GC.opsMemoryType = kernelMemoryType,
      GC.opsWriteScalar = kernelWriteScalar,
      GC.opsReadScalar = kernelReadScalar,
      GC.opsAllocate = cannotAllocate,
      GC.opsDeallocate = cannotDeallocate,
      GC.opsCopy = copyInKernel,
      GC.opsStaticArray = noStaticArrays,
      GC.opsFatMemory = False,
      GC.opsError = errorInKernel,
      GC.opsCall = callInKernel,
      GC.opsCritical = mempty
    }
  where
    has_communication = hasCommunication body

    fence FenceLocal = [C.cexp|CLK_LOCAL_MEM_FENCE|]
    fence FenceGlobal = [C.cexp|CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE|]

    kernelOps :: GC.OpCompiler KernelOp KernelState
    kernelOps (GetGroupId v i) =
      GC.stm [C.cstm|$id:v = get_group_id($int:i);|]
    kernelOps (GetLocalId v i) =
      GC.stm [C.cstm|$id:v = get_local_id($int:i);|]
    kernelOps (GetLocalSize v i) =
      GC.stm [C.cstm|$id:v = get_local_size($int:i);|]
    kernelOps (GetGlobalId v i) =
      GC.stm [C.cstm|$id:v = get_global_id($int:i);|]
    kernelOps (GetGlobalSize v i) =
      GC.stm [C.cstm|$id:v = get_global_size($int:i);|]
    kernelOps (GetLockstepWidth v) =
      GC.stm [C.cstm|$id:v = LOCKSTEP_WIDTH;|]
    kernelOps (Barrier f) = do
      GC.stm [C.cstm|barrier($exp:(fence f));|]
      GC.modifyUserState $ \s -> s {kernelHasBarriers = True}
    kernelOps (MemFence FenceLocal) =
      GC.stm [C.cstm|mem_fence_local();|]
    kernelOps (MemFence FenceGlobal) =
      GC.stm [C.cstm|mem_fence_global();|]
    kernelOps (LocalAlloc name size) = do
      name' <- newVName $ pretty name ++ "_backing"
      GC.modifyUserState $ \s ->
        s {kernelLocalMemory = (name', fmap untyped size) : kernelLocalMemory s}
      GC.stm [C.cstm|$id:name = (__local unsigned char*) $id:name';|]
    kernelOps (ErrorSync f) = do
      label <- nextErrorLabel
      pending <- kernelSyncPending <$> GC.getUserState
      when pending $ do
        pendingError False
        GC.stm [C.cstm|$id:label: barrier($exp:(fence f));|]
        GC.stm [C.cstm|if (local_failure) { return; }|]
      GC.stm [C.cstm|barrier($exp:(fence f));|]
      GC.modifyUserState $ \s -> s {kernelHasBarriers = True}
      incErrorLabel
    kernelOps (Atomic space aop) = atomicOps space aop

    atomicCast s t = do
      let volatile = [C.ctyquals|volatile|]
      quals <- case s of
        Space sid -> pointerQuals sid
        _ -> pointerQuals "global"
      return [C.cty|$tyquals:(volatile++quals) $ty:t|]

    atomicSpace (Space sid) = sid
    atomicSpace _ = "global"

    doAtomic s t old arr ind val op ty = do
      ind' <- GC.compileExp $ untyped $ unCount ind
      val' <- GC.compileExp val
      cast <- atomicCast s ty
      GC.stm [C.cstm|$id:old = $id:op'(&(($ty:cast *)$id:arr)[$exp:ind'], ($ty:ty) $exp:val');|]
      where
        op' = op ++ "_" ++ pretty t ++ "_" ++ atomicSpace s

    doAtomicCmpXchg s t old arr ind cmp val ty = do
      ind' <- GC.compileExp $ untyped $ unCount ind
      cmp' <- GC.compileExp cmp
      val' <- GC.compileExp val
      cast <- atomicCast s ty
      GC.stm [C.cstm|$id:old = $id:op(&(($ty:cast *)$id:arr)[$exp:ind'], $exp:cmp', $exp:val');|]
      where
        op = "atomic_cmpxchg_" ++ pretty t ++ "_" ++ atomicSpace s
    doAtomicXchg s t old arr ind val ty = do
      cast <- atomicCast s ty
      ind' <- GC.compileExp $ untyped $ unCount ind
      val' <- GC.compileExp val
      GC.stm [C.cstm|$id:old = $id:op(&(($ty:cast *)$id:arr)[$exp:ind'], $exp:val');|]
      where
        op = "atomic_chg_" ++ pretty t ++ "_" ++ atomicSpace s
    -- First the 64-bit operations.
    atomicOps s (AtomicAdd Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_add" [C.cty|typename int64_t|]
    atomicOps s (AtomicFAdd Float64 old arr ind val) =
      doAtomic s Float64 old arr ind val "atomic_fadd" [C.cty|double|]
    atomicOps s (AtomicSMax Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_smax" [C.cty|typename int64_t|]
    atomicOps s (AtomicSMin Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_smin" [C.cty|typename int64_t|]
    atomicOps s (AtomicUMax Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_umax" [C.cty|unsigned int64_t|]
    atomicOps s (AtomicUMin Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_umin" [C.cty|unsigned int64_t|]
    atomicOps s (AtomicAnd Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_and" [C.cty|typename int64_t|]
    atomicOps s (AtomicOr Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_or" [C.cty|typename int64_t|]
    atomicOps s (AtomicXor Int64 old arr ind val) =
      doAtomic s Int64 old arr ind val "atomic_xor" [C.cty|typename int64_t|]
    atomicOps s (AtomicCmpXchg (IntType Int64) old arr ind cmp val) =
      doAtomicCmpXchg s (IntType Int64) old arr ind cmp val [C.cty|typename int64_t|]
    atomicOps s (AtomicXchg (IntType Int64) old arr ind val) =
      doAtomicXchg s (IntType Int64) old arr ind val [C.cty|typename int64_t|]
    --
    atomicOps s (AtomicAdd t old arr ind val) =
      doAtomic s t old arr ind val "atomic_add" [C.cty|int|]
    atomicOps s (AtomicFAdd t old arr ind val) =
      doAtomic s t old arr ind val "atomic_fadd" [C.cty|float|]
    atomicOps s (AtomicSMax t old arr ind val) =
      doAtomic s t old arr ind val "atomic_smax" [C.cty|int|]
    atomicOps s (AtomicSMin t old arr ind val) =
      doAtomic s t old arr ind val "atomic_smin" [C.cty|int|]
    atomicOps s (AtomicUMax t old arr ind val) =
      doAtomic s t old arr ind val "atomic_umax" [C.cty|unsigned int|]
    atomicOps s (AtomicUMin t old arr ind val) =
      doAtomic s t old arr ind val "atomic_umin" [C.cty|unsigned int|]
    atomicOps s (AtomicAnd t old arr ind val) =
      doAtomic s t old arr ind val "atomic_and" [C.cty|int|]
    atomicOps s (AtomicOr t old arr ind val) =
      doAtomic s t old arr ind val "atomic_or" [C.cty|int|]
    atomicOps s (AtomicXor t old arr ind val) =
      doAtomic s t old arr ind val "atomic_xor" [C.cty|int|]
    atomicOps s (AtomicCmpXchg t old arr ind cmp val) =
      doAtomicCmpXchg s t old arr ind cmp val [C.cty|int|]
    atomicOps s (AtomicXchg t old arr ind val) =
      doAtomicXchg s t old arr ind val [C.cty|int|]

    cannotAllocate :: GC.Allocate KernelOp KernelState
    cannotAllocate _ =
      error "Cannot allocate memory in kernel"

    cannotDeallocate :: GC.Deallocate KernelOp KernelState
    cannotDeallocate _ _ =
      error "Cannot deallocate memory in kernel"

    copyInKernel :: GC.Copy KernelOp KernelState
    copyInKernel _ _ _ _ _ _ _ =
      error "Cannot bulk copy in kernel."

    noStaticArrays :: GC.StaticArray KernelOp KernelState
    noStaticArrays _ _ _ _ =
      error "Cannot create static array in kernel."

    kernelMemoryType space = do
      quals <- pointerQuals space
      return [C.cty|$tyquals:quals $ty:defaultMemBlockType|]

    kernelWriteScalar =
      GC.writeScalarPointerWithQuals pointerQuals

    kernelReadScalar =
      GC.readScalarPointerWithQuals pointerQuals

    whatNext = do
      label <- nextErrorLabel
      pendingError True
      return $
        if has_communication
          then [C.citems|local_failure = true; goto $id:label;|]
          else
            if mode == FunMode
              then [C.citems|return 1;|]
              else [C.citems|return;|]

    callInKernel dests fname args
      | isBuiltInFunction fname =
        GC.opsCall GC.defaultOperations dests fname args
      | otherwise = do
        let out_args = [[C.cexp|&$id:d|] | d <- dests]
            args' =
              [C.cexp|global_failure|] :
              [C.cexp|global_failure_args|] :
              out_args ++ args

        what_next <- whatNext

        GC.item [C.citem|if ($id:(funName fname)($args:args') != 0) { $items:what_next; }|]

    errorInKernel msg@(ErrorMsg parts) backtrace = do
      n <- length . kernelFailures <$> GC.getUserState
      GC.modifyUserState $ \s ->
        s {kernelFailures = kernelFailures s ++ [FailureMsg msg backtrace]}
      let setArgs _ [] = return []
          setArgs i (ErrorString {} : parts') = setArgs i parts'
          -- FIXME: bogus for non-ints.
          setArgs i (ErrorVal _ x : parts') = do
            x' <- GC.compileExp x
            stms <- setArgs (i + 1) parts'
            return $ [C.cstm|global_failure_args[$int:i] = (typename int64_t)$exp:x';|] : stms
      argstms <- setArgs (0 :: Int) parts

      what_next <- whatNext

      GC.stm
        [C.cstm|{ if (atomic_cmpxchg_i32_global(global_failure, -1, $int:n) == -1)
                                 { $stms:argstms; }
                                 $items:what_next
                               }|]

--- Checking requirements

typesInKernel :: Kernel -> S.Set PrimType
typesInKernel kernel = typesInCode $ kernelBody kernel

typesInCode :: ImpGPU.KernelCode -> S.Set PrimType
typesInCode Skip = mempty
typesInCode (c1 :>>: c2) = typesInCode c1 <> typesInCode c2
typesInCode (For _ e c) = typesInExp e <> typesInCode c
typesInCode (While (TPrimExp e) c) = typesInExp e <> typesInCode c
typesInCode DeclareMem {} = mempty
typesInCode (DeclareScalar _ _ t) = S.singleton t
typesInCode (DeclareArray _ _ t _) = S.singleton t
typesInCode (Allocate _ (Count (TPrimExp e)) _) = typesInExp e
typesInCode Free {} = mempty
typesInCode
  ( Copy
      _
      (Count (TPrimExp e1))
      _
      _
      (Count (TPrimExp e2))
      _
      (Count (TPrimExp e3))
    ) =
    typesInExp e1 <> typesInExp e2 <> typesInExp e3
typesInCode (Write _ (Count (TPrimExp e1)) t _ _ e2) =
  typesInExp e1 <> S.singleton t <> typesInExp e2
typesInCode (Read _ _ (Count (TPrimExp e1)) t _ _) =
  typesInExp e1 <> S.singleton t
typesInCode (SetScalar _ e) = typesInExp e
typesInCode SetMem {} = mempty
typesInCode (Call _ _ es) = mconcat $ map typesInArg es
  where
    typesInArg MemArg {} = mempty
    typesInArg (ExpArg e) = typesInExp e
typesInCode (If (TPrimExp e) c1 c2) =
  typesInExp e <> typesInCode c1 <> typesInCode c2
typesInCode (Assert e _ _) = typesInExp e
typesInCode (Comment _ c) = typesInCode c
typesInCode (DebugPrint _ v) = maybe mempty typesInExp v
typesInCode (TracePrint msg) = foldMap typesInExp msg
typesInCode Op {} = mempty

typesInExp :: Exp -> S.Set PrimType
typesInExp (ValueExp v) = S.singleton $ primValueType v
typesInExp (BinOpExp _ e1 e2) = typesInExp e1 <> typesInExp e2
typesInExp (CmpOpExp _ e1 e2) = typesInExp e1 <> typesInExp e2
typesInExp (ConvOpExp op e) = S.fromList [from, to] <> typesInExp e
  where
    (from, to) = convOpType op
typesInExp (UnOpExp _ e) = typesInExp e
typesInExp (FunExp _ args t) = S.singleton t <> mconcat (map typesInExp args)
typesInExp LeafExp {} = mempty
