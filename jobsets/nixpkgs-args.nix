# The arguments the CUDA packages (./cuda-packages.nix) and GPU checks (./cuda-tests.nix) jobsets import Nixpkgs with:
# for their jobs, through release-lib, and for nix-nixpkgs-review's reports, whose evaluation imports this file as their
# `nixpkgsArgs` (which is passed `withCA` as well).
{ withCUDA, ... }:
{
  config = {
    # TODO: why not simply "allowUnfree = true"?
    # allowUnfreePredicate =
    #   let
    #     cudaLib = (import "${nixpkgs}/pkgs/development/cuda-modules/_cuda").lib;
    #   in
    #   cudaLib.allowUnfreeCudaPredicate;
    allowUnfree = true;
    cudaSupport = withCUDA;
    inHydra = true;

    # Don't evaluate duplicate and/or deprecated attributes
    allowAliases = false;
  };

  __allowFileset = false;
}
