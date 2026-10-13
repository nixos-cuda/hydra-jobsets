let
  common = [
    # cudaPackages
    "cudaPackages.cudatoolkit"
    "cudaPackages.cudnn"
    "cudaPackages.libcusolver"
    "cudaPackages.libcusolvermp"
    "cudaPackages.nvbandwidth"
    "cudaPackages.saxpy"
    "cudaPackages.saxpy.gpuCheck"

    # Other cudaPackages versions
    "cudaPackages_12.cudatoolkit"
    "cudaPackages_12_6.cudatoolkit"
    "cudaPackages_12_8.cudatoolkit"
    "cudaPackages_12_9.cudatoolkit"
    "cudaPackages_13.cudatoolkit"
    "cudaPackages_13_0.cudatoolkit"
    "cudaPackages_13_1.cudatoolkit"
    "cudaPackages_13_2.cudatoolkit"

    # Misc packages
    "blender"
    "blender.tests.tester-cudaAvailable.gpuCheck"
    "firefox-unwrapped" # depends on onnxruntime
    "tiny-cuda-nn"
    "python3Packages.nvidia-ml-py.tests.tester-nvmlInit.gpuCheck"

    # ONNX
    "onnxruntime"
    "python3Packages.onnx"
    "python3Packages.onnxruntime"

    # OpenCV
    "opencv"
    "opencv4"
    "python3Packages.opencv4"

    # LLM
    "llama-cpp"
    "ollama"
    # vllm < 0.20.0 has known vulnerabilities
    # TODO: re-enable when possible
    #"python3Packages.vllm"

    # Python / CUDA
    "python3Packages.cuda-bindings"
    "python3Packages.cuda-bindings.gpuCheck"
    "python3Packages.cuda-pathfinder"

    # Python / Misc
    "python3Packages.cupy"
    "python3Packages.numba"

    # Python / Deep Learning
    "python3Packages.jax"
    "python313Packages.tensorflow" # tensorflow is not abailable on python 3.14
    "python3Packages.tiny-cuda-nn"
    "python3Packages.tinygrad"
    "python3Packages.tinygrad.gpuCheck"
    "python3Packages.tinygrad.tests.withCuda.gpuCheck"
    # "xla": unavailable on CUDA 13.4 (among others)

    # PyTorch
    "python3Packages.torch"
    "python3Packages.torch.tests.tester-compileCpu.gpuCheck"
    "python3Packages.torch.tests.tester-compileCuda.gpuCheck"
    "python3Packages.torch.tests.tester-cudaAvailable.gpuCheck"
    "python3Packages.torchaudio"
    "python3Packages.torchaudio.gpuCheck"
    "python3Packages.torchvision"
    "python3Packages.triton"
    "python3Packages.triton-cuda.tests.axpy-cuda.gpuCheck"
    "python3Packages.triton.gpuCheck"
  ];
in
{
  nixos-unstable-cuda = common ++ [
    # Other cudaPackages versions
    "cudaPackages_13_3.cudatoolkit"
    "cudaPackages_13_4.cudatoolkit"

    # Python / CUDA
    "python3Packages.cuda-cccl"
    "python3Packages.cuda-cccl.gpuCheck"
    "python3Packages.cuda-core"
    "python3Packages.cuda-core.gpuCheck"
    "python3Packages.cuda-tile"
    "python3Packages.cuda-tile.gpuCheck"
    "python3Packages.nvidia-cutlass-dsl"

    # Python / Misc
    "python3Packages.numba-cuda"
    "python3Packages.numba-cuda.gpuCheck"
  ];
  "nixos-26.05-cuda" = common ++ [
    # Only adding it here as it is unavailable for CUDA 13.4
    # TODO: re-enable when possible
    "mistral-rs"
  ];
}
