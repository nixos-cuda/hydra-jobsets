# The arguments the CUDA packages (./cuda-packages.nix), GPU checks (./cuda-tests.nix) and channel (./cuda-channel)
# jobsets import Nixpkgs with: for their jobs, through release-lib, and for nix-nixpkgs-review's reports, whose
# evaluation imports this file as their `nixpkgsArgs` (which is passed `withCA` as well).
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
