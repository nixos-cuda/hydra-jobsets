let
  common = [
    # cudaPackages

    # Web browsers
    "firefox-unwrapped"
    "chromium"
    "ungoogled-chromium"

    "opencv"

    # Deep Learning
    "python3Packages.torch"
    "python3Packages.torch.tests.tester-compileCpu.gpuCheck"
  ];
in
{
  nixos-unstable-cuda = common ++ [

  ];
  "nixos-25.11-cuda" = common ++ [

  ];
}
