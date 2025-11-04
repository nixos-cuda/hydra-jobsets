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
  ...
}@args:

let
  ##########################################################
  # STEP 1: Initialize release-lib
  ##########################################################

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

  ##########################################################
  # STEP 2: Compute the set of attrpaths in nixpkgs that are affected by switching cudaSupport from
  # `false` to `true`
  ##########################################################

  ci = import "${nixpkgs}/ci" {
    system = currentSystem;
    inherit nixpkgs;
  };

  # TODO: optimize the value of chunkSize for the hydra machine
  evalCudaSupportFalse =
    (ci.eval {
      extraNixpkgsConfig = nixpkgsConfig // {
        cudaSupport = false;
      };
    }).baseline
      { evalSystems = supportedSystems; };

  evalComparison =
    (ci.eval {
      extraNixpkgsConfig = nixpkgsConfig;
    }).full
      {
        baseline = evalCudaSupportFalse;
        evalSystems = supportedSystems;
      };

  inherit (lib.importJSON "${evalComparison}/changed-paths.json") rebuildsByPlatform;

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # First, we need to map
  #
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
  #
  # to:
  #
  # allPackagePlatforms = {
  #   python3Packages.torch = [ "x86_64-linux" "aarch64-linux" ];
  #   python3Packages.foo = [ "x86_64-linux" ];
  #   python3Packages.bar = [ "aarch64-linux" ];
  #   cool = [ "x86_64-linux" "aarch64-linux" ];
  # }
  #
  # thanks to some nix magic by @MattSturgeon (thanks!)

  toEntries =
    x:
    lib.pipe x [
      (lib.mapAttrs (
        system:
        map (pathStr: {
          inherit system;
          path = lib.splitString "." pathStr;
        })
      ))
      lib.attrValues
      lib.concatLists
    ];

  groupEntries =
    entries:
    lib.pipe entries [
      (lib.groupBy (entry: lib.head entry.path))
      (lib.mapAttrs (_: map (entry: entry // { path = lib.tail entry.path; })))
    ];

  entriesToAttrSet =
    entries:
    lib.mapAttrs (
      _: entries:
      let
        byLeaf = lib.partition (entry: entry.path == [ ]) entries;
      in
      if byLeaf.wrong == [ ] then
        # leaf node
        lib.catAttrs "system" entries
      else if byLeaf.right == [ ] then
        # recursive
        entriesToAttrSet entries
      else
        throw "Conflicting attr paths:${lib.concatMapStrings (entry: "\n- ${entry.path}") entries}"
    ) (groupEntries entries);

  allPackagePlatforms = entriesToAttrSet (toEntries rebuildsByPlatform);

  # Explicitly specified platforms take precedence over the platforms
  # automatically inferred in autoPackagePlatforms
  jobs = release-lib.mapTestOn allPackagePlatforms;
in
jobs
