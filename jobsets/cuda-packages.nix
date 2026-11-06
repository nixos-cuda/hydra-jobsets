{
  # The platforms supported by the NixOS-CUDA Hydra instance
  supportedSystems ? [
    "x86_64-linux"
    "aarch64-linux"
  ],
  # The system evaluating this expression
  # TODO: automatically detect?
  currentSystem ? builtins.currentSystem or "x86_64-linux",

  # The nixpkgs instance
  nixpkgs,

  # https://github.com/ConnorBaker/nix-nixpkgs-review, which evaluates Nixpkgs and compares the results
  nixNixpkgsReview,
  # The Nix evaluator nixNixpkgsReview's evaluations run with (a `build` input: the tools jobset's iets, for the system
  # Hydra evaluates on)
  iets,
  ...
}@args:

let
  ##########################################################
  # STEP 1: Initialize release-lib
  ##########################################################

  lib = import "${nixpkgs}/lib";
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";

  release-lib = mkReleaseLib (
    {
      inherit supportedSystems;
      nixpkgsArgs = import ./nixpkgs-args.nix { withCUDA = true; };
      system = currentSystem;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );

  ##########################################################
  # STEP 2: The attribute paths enabling cudaSupport adds, changes or fixes, per system
  ##########################################################

  reports = import ./reports.nix {
    inherit
      nixpkgs
      nixNixpkgsReview
      iets
      currentSystem
      ;
  };
  changedOn =
    system:
    reports.cudaSensitive (reports.report "noCuda-${system}" nixpkgs system false) (
      reports.report "cuda-${system}" nixpkgs system true
    );

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # e.g. { cudaPackages.cudnn.x86_64-linux = <drv>; python3Packages.torch.aarch64-linux = <drv>; }
  jobs = import ./release-jobs.nix {
    inherit lib;
    releaseLib = release-lib;
  } (job: job) supportedSystems changedOn;
in
jobs
