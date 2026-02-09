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
  inherit (release-lib) linux;

  processPackage =
    package:
    let
      passthruEval = builtins.tryEval (package.passthru or { });
      pname = package.pname or "???";

      tests =
        let
          testsEval = builtins.tryEval (passthruEval.value.tests or { });
        in
        if testsEval.success then testsEval.value else { };

      hasCudaGpuCheck =
        v:
        let
          hasGpuCheck = v ? "gpuCheck";
          # Only build gpuCheck instances which explicitly require a CUDA-enabled GPU
          requiresCuda = builtins.elem "cuda" (v.gpuCheck.requiredSystemFeatures or [ ]);
        in
        hasGpuCheck && requiresCuda;

      testGpuChecks = lib.mapAttrs (
        testName: test:
        lib.optionalAttrs (hasCudaGpuCheck test) {
          gpuCheck = linux;
        }
      ) tests;
    in
    if
      !(builtins.elem pname [
        # error: attribute 'cassandra_4' missing
        "cassandra"

        # {git,git-with-svn,git-minimal}.tests.withGitConfig fails to evaluate
        # import ../../.. without system arg
        "git"
        "git-with-svn"
        "git-minimal"
      ])
      && passthruEval.success
    then
      # <package>.passthru.tests.*.gpuCheck
      lib.optionalAttrs (testGpuChecks != { }) { tests = testGpuChecks; }

      # <package>.passthru.gpuCheck
      // lib.optionalAttrs (hasCudaGpuCheck passthruEval.value) {
        gpuCheck = linux;
      }
    else
      [ ];

  recursiveMapPackages' =
    path: f:
    lib.mapAttrs (
      name: value:
      # Ignore tests.fetchgit.withGitConfig as it fails to evaluate
      if name == "withGitConfig" then
        [ ]
      else if lib.isDerivation value then
        f value
      else if value.recurseForDerivations or false || value.recurseForRelease or false then
        recursiveMapPackages' (path ++ [ name ]) f value
      else
        [ ]
    );

  /*
    {
      foo.tests.testName.gpuCheck = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
    }
  */
  gpuChecksTree = recursiveMapPackages' [ ] processPackage release-lib.pkgs;

  /*
    {
      foo.tests.testName.gpuCheck.x86_64-linux = <derivation>;
    }
  */
  jobs = release-lib.mapTestOn gpuChecksTree;
in
jobs
