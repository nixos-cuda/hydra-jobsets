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
  # STEP 2: Compute the set of attrpaths in nixpkgs that are affected by switching cudaSupport from
  # `false` to `true`
  ##########################################################

  # Used for simple IFDs
  pkgs = import nixpkgs {
    system = currentSystem;
    config = { };
    overlays = [ ];
  };

  # mkReport evaluates Nixpkgs in a derivation (read with import-from-derivation), as one JSON line per job; mkJobs
  # compares two (see nix-nixpkgs-review's lib.nix).
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  # The attribute paths added, changed, or fixed (that fail to evaluate without cudaSupport) by enabling cudaSupport on
  # a system.
  changedOn =
    system:
    let
      mkReport =
        withCUDA:
        nixNixpkgsReviewLib.mkReport {
          label = "${if withCUDA then "cuda" else "noCuda"}-${system}";
          tree = nixpkgs;
          evalSystem = system;
          inherit withCUDA;
          nixpkgsArgs = ./report-args.nix;
          extraJobs = ./release-extra-jobs.nix;
        };
    in
    lib.importJSON "${
      nixNixpkgsReviewLib.mkJobs {
        pre = mkReport false;
        post = mkReport true;
      }
    }/changed.json";

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
