{
  # The platforms supported by the NixOS-CUDA Hydra instance
  supportedSystems ? [
    "x86_64-linux"
    # "aarch64-linux"
  ],
  # The system evaluating this expression
  # TODO: automatically detect?
  currentSystem ? builtins.currentSystem or "x86_64-linux",

  # The nixpkgs instance
  nixpkgs,

  # "nixos-unstable-cuda", "nixos-25.11-cuda", ...
  channelName,
  ...
}@args:

let
  lib = import "${nixpkgs}/lib";
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";

  nixpkgsConfig = {
    # TODO: why not simply "allowUnfree = true"?
    # allowUnfreePredicate =
    #   let
    #     cudaLib = (import "${nixpkgs}/pkgs/development/cuda-modules/_cuda").lib;
    #   in
    #   cudaLib.allowUnfreeCudaPredicate;
    allowUnfree = true;
    cudaSupport = true;
    inHydra = true;

    # Don't evaluate duplicate and/or deprecated attributes
    allowAliases = false;
  };

  # Attributes passed to nixpkgs.
  nixpkgsArgs = {
    config = nixpkgsConfig;
    __allowFileset = false;
  };

  release-lib = mkReleaseLib (
    {
      inherit supportedSystems nixpkgsArgs;
      system = currentSystem;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );

  inherit (release-lib) pkgs;
  inherit (lib) concatStringsSep isDerivation;

  cudaPackagesJobs = import ./cuda-packages-jobs.nix {
    inherit lib release-lib;
  };

  jobsFromChannelBlockers = import ./jobs-from-channel-blockers.nix {
    inherit
      lib
      release-lib
      channelName
      ;
    channelBlockers = (import ../../channel-blockers.nix).${channelName};
  };

  jobs = cudaPackagesJobs // jobsFromChannelBlockers;

  allJobNames =
    lib.mapAttrsToListRecursiveCond
      # Recurse into non-derivations
      (path: as: !(isDerivation as))

      # Collect all paths
      (path: value: concatStringsSep "." path)

      jobs;

  # Aggregate job that signals that everything passes
  _tested = pkgs.releaseTools.aggregate {
    name = channelName;
    meta = { };
    constituents = allJobNames;
  };
in
jobs // { inherit _tested; }
