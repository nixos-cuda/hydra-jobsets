# The arguments the CUDA packages (./cuda-packages.nix), GPU checks (./cuda-tests.nix) and channel (./cuda-channel)
# jobsets import Nixpkgs with for their jobs, through release-lib. Their reports use ./report-args.nix and
# ./gpu-report-args.nix.
{ withCUDA, ... }:
{
  config = {
    allowUnfree = true;
    cudaSupport = withCUDA;
    inHydra = true;

    # Don't evaluate duplicate and/or deprecated attributes
    allowAliases = false;
  };

  __allowFileset = false;
}
