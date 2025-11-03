{
  # The platforms supported by the NixOS-CUDA Hydra instance
  supportedSystems ? [
    "x86_64-linux"
    # "aarch64-linux"
  ],
  # The system evaluating this expression
  # TODO: automatically detect?
  currentSystem ? "x86_64-linux",

  # The nixpkgs instance
  nixpkgs,
  ...
}@args:

let
  ##########################################################
  # STEP 1: Initialize release-lib
  ##########################################################

  lib = import "${nixpkgs}/lib";
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";

  # Attributes passed to nixpkgs.
  nixpkgsArgs = {
    config = {
      # TODO: why not simply "allowUnfree = true"?
      allowUnfreePredicate =
        let
          cudaLib = (import "${nixpkgs}/pkgs/development/cuda-modules/_cuda").lib;
        in
        cudaLib.allowUnfreeCudaPredicate;
      cudaSupport = true;
      inHydra = true;

      # Don't evaluate duplicate and/or deprecated attributes
      allowAliases = false;
    };

    __allowFileset = false;
  };

  release-lib = mkReleaseLib (
    {
      inherit supportedSystems nixpkgsArgs;
      system = currentSystem;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );

  ##########################################################
  # STEP 2: Compute the set of attrpaths in nixpkgs that are affected by switching cudaSupport from
  # `false` to `true`
  ##########################################################

  ci = import "${nixpkgs}/ci" {
    system = currentSystem;
    inherit nixpkgs;
  };

  evalCudaSupportFalse =
    (ci.eval {
      extraNixpkgsConfig = {
        allowUnfree = true;
        cudaSupport = false;
      };
    }).baseline
      { evalSystems = supportedSystems; };

  evalComparison =
    (ci.eval {
      extraNixpkgsConfig = {
        allowUnfree = true;
        cudaSupport = true;
      };
    }).full
      {
        baseline = evalCudaSupportFalse;
        evalSystems = supportedSystems;
      };

  inherit (lib.importJSON "${evalComparison}/changed-paths.json") rebuildsByPlatform;

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # Previous manual mapping declared in pkgs/top-level/release-cuda.nix
  # allPackagePlatforms = {
  #   blas = linux;
  #   blender = linux;
  #   python3Packages.torch = linux;
  # };

  allPackagePlatforms = lib.foldlAttrs (
    acc: system:
    let
      foldPaths = lib.foldl (
        acc: str:
        let
          res = lib.setAttrByPath (lib.splitString "." str) system;
        in
        lib.recursiveUpdate acc res
      );
    in
    foldPaths acc
  ) { } rebuildsByPlatform;

  # We need to go from
  # rebuildsByPlatform = {
  #   "x86_64-linux" = [
  #     "python3Packages.torch"
  #     "python3Packages.foo"
  #     "cool"
  #   ];
  #   "aarch64-linux" = [
  #     "python3Packages.torch"
  #     "python3Packages.bar"
  #     "cool"
  #   ];
  # }
  # to:
  # {
  #   python3Packages.torch = [ "x86_64-linux" "aarch64-linux" ];
  #   python3Packages.foo = [ "x86_64-linux" ];
  #   python3Packages.bar = [ "aarch64-linux" ];
  #   cool = [ "x86_64-linux" "aarch64-linux" ];
  # }
  # Then, we can feed this to mapTestOn

  # Explicitly specified platforms take precedence over the platforms
  # automatically inferred in autoPackagePlatforms
  jobs = release-lib.mapTestOn allPackagePlatforms;
in
# jobs
lib.generators.toPretty { } jobs # TODO: FOR DEBUG PURPOSES
