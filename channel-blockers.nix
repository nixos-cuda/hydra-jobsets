let
  common = [
    # cudaPackages
    "cudaPackages.cudatoolkit"
    "cudaPackages.saxpy"
    "cudaPackages.saxpy.gpuCheck"

    # Other cudaPackages versions
    "cudaPackages_12.cudatoolkit"
    "cudaPackages_12_6.cudatoolkit"
    "cudaPackages_12_8.cudatoolkit"
    "cudaPackages_12_9.cudatoolkit"
    "cudaPackages_13.cudatoolkit"
    "cudaPackages_13_0.cudatoolkit"

    # Web browsers
    "firefox-unwrapped"
    "chromium"
    "ungoogled-chromium"

    # Misc packages
    "blender"
    "blender.tests.tester-cudaAvailable.gpuCheck"
    "tiny-cuda-nn"

    # ONNX
    "onnxruntime"
    "python3Packages.onnx"
    "python3Packages.onnxruntime"

    # OpenCV
    "opencv"
    "opencv4"
    "python3Packages.opencv"
    "python3Packages.opencv4"

    # LLM
    "llama-cpp"
    "mistral-rs"
    "ollama"
    "python3Packages.vllm"

    # Python / Deep Learning
    "python3Packages.cuda-bindings.gpuCheck"
    "python3Packages.jax"
    "python3Packages.tensorflow"
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
    "python3Packages.torchvision"
    "python3Packages.triton"
    "python3Packages.triton-cuda.tests.axpy-cuda.gpuCheck"
    "python3Packages.triton.gpuCheck"
  ];
in
{
  nixos-unstable-cuda = common ++ [

  ];
  "nixos-25.11-cuda" = common ++ [

  ];
}
