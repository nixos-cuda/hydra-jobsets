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

  # The arguments Nixpkgs is imported with, as a function of { withCUDA, ... }: the same file configures the jobs
  # (through release-lib) and the reports (as nix-nixpkgs-review's `nixpkgsArgs`).
  nixpkgsArgsFile = ./nixpkgs-args.nix;

  release-lib = mkReleaseLib (
    {
      inherit supportedSystems;
      nixpkgsArgs = import nixpkgsArgsFile { withCUDA = true; };
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

  # nixNixpkgsReview's mkReport evaluates Nixpkgs in a derivation (import-from-derivation) with iets' eval-jobs,
  # recording the output paths of every job, and the error of every attribute that fails to evaluate, without
  # instantiating anything. mkJobs compares two reports: its diff.json lists the attribute paths added, changed,
  # removed, broken and fixed.
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  # Per system: Nixpkgs without and with cudaSupport, evaluated exactly as release-lib does for the jobs.
  reports = lib.genAttrs supportedSystems (
    system:
    lib.genAttrs [ "noCuda" "cuda" ] (
      variant:
      nixNixpkgsReviewLib.mkReport {
        label = "${variant}-${system}";
        tree = nixpkgs;
        evalSystem = system;
        withCUDA = variant == "cuda";
        nixpkgsArgs = nixpkgsArgsFile;
      }
    )
  );

  # The attribute paths added, changed, or fixed (that fail to evaluate without cudaSupport) by enabling cudaSupport on
  # a system. Each diff also depends on every report, so that the first diff evaluation reads (as
  # import-from-derivation) has Nix build all the reports at once, as many in parallel as Hydra's `--max-jobs`
  # (`evaluator_max_jobs`) allows.
  changedOn =
    system:
    let
      inherit
        (lib.importJSON "${
          nixNixpkgsReviewLib.mkJobs {
            pre = reports.${system}.noCuda;
            post = reports.${system}.cuda;
            after = lib.concatMap lib.attrValues (lib.attrValues reports);
          }
        }/diff.json")
        added
        changed
        fixed
        ;
    in
    added ++ changed ++ fixed;

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # e.g. { cudaPackages.cudnn.x86_64-linux = <drv>; python3Packages.torch.aarch64-linux = <drv>; }
  jobs =
    import ./release-jobs.nix
      {
        inherit lib;
        releaseLib = release-lib;
      }
      (job: job)
      (lib.concatMap (system: map (path: { inherit system path; }) (changedOn system)) supportedSystems);
in
jobs
