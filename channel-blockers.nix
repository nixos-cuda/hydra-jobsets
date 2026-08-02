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
    "mistral-rs"
    "ollama"
    # vllm < 0.20.0 has known vulnerabilities
    # TODO: re-enable when possible
    #"python3Packages.vllm"

    # Python / Deep Learning
    "python3Packages.cuda-bindings"
    "python3Packages.cuda-bindings.gpuCheck"
    "python3Packages.jax"
    "python313Packages.tensorflow" # tensorflow is not abailable on python 3.14
    "python3Packages.tiny-cuda-nn"
    "python3Packages.tinygrad"
    "python3Packages.tinygrad.gpuCheck"
    "python3Packages.tinygrad.tests.withCuda.gpuCheck"

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
  ];
  "nixos-26.05-cuda" = common ++ [
  ];
}
