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

      # Test discovery follows the documented Nixpkgs CUDA testing convention
      # (doc/languages-frameworks/cuda.section.md): tests live in
      # `passthru.tests` -- CUDA-specific ones nested, e.g. `tests.cuda.<name>`
      # -- and carry `requiredSystemFeatures = [ "cuda" ]` so they only run on
      # machines exposing a CUDA-capable GPU. Discovery is therefore
      # capability-based: any such test is picked up, whatever it is named.
      # Tests requiring `rocm` are skipped: they need an AMD GPU, which the
      # CUDA builders do not have.
      requiresCuda =
        value:
        let
          eval = builtins.tryEval (
            let
              features = value.requiredSystemFeatures or [ ];
            in
            builtins.elem "cuda" features && !(builtins.elem "rocm" features)
          );
        in
        eval.success && eval.value;

      # Map a `passthru.tests` subtree to a release-lib platform tree, lazily:
      # the shape mirrors the tests attrset, with the platform list `linux` as
      # the leaf wherever a test requires the CUDA system feature. Evaluating
      # lazily matters: packages can sit close to Nix's call-depth limit
      # (e.g. `tinygrad.tests.withCuda.gpuCheck` nests package overrides), and
      # the old, lazy discovery survived there where an eager traversal
      # overflows.
      #
      # Derivations expose their passthru attributes as derivation members, so
      # a `writeGpuTestPython` tester placed at `tests.<name>` has its
      # `gpuCheck` member visited like a nested attribute, yielding the
      # historical `tests.<name>.gpuCheck` job paths. A `gpuCheck` member is
      # then treated as a leaf: `passthru.tests` may contain package overrides
      # (e.g. `tinygrad.tests.withCuda = tinygrad.override { ... }`) whose
      # `gpuCheck` members lead back to more overrides, so re-descending those
      # chains would force pathological (or even cyclic) passthru evaluation.
      #
      # Each node is guarded so one broken package does not fail the jobset.
      testsTree =
        value:
        let
          node = builtins.tryEval (
            if lib.isDerivation value then
              if value ? gpuCheck then
                { gpuCheck = gpuCheckTree value.gpuCheck; }
              else if requiresCuda value then
                linux
              else
                { }
            else if lib.isAttrs value then
              # `passthru.tests` may contain non-attrset members (e.g. flags);
              # the old discovery tolerated them via `? "gpuCheck"`.
              lib.mapAttrs (_: testsTree) value
            else
              { }
          );
        in
        if node.success then node.value else { };

      gpuCheckTree =
        value:
        let
          node = builtins.tryEval (if requiresCuda value then linux else { });
        in
        if node.success then node.value else { };

      tests =
        let
          testsEval = builtins.tryEval (passthruEval.value.tests or { });
        in
        if testsEval.success then testsEval.value else { };

      # The top-level `passthru.gpuCheck` convention, e.g. `writeGpuTestPython`'s
      # default output shape (`cudaPackages.saxpy.gpuCheck`).
      topGpuCheck =
        let
          node = builtins.tryEval (
            if passthruEval.value ? gpuCheck && requiresCuda passthruEval.value.gpuCheck then
              { gpuCheck = linux; }
            else
              { }
          );
        in
        if node.success then node.value else { };

      # e.g.
      #   {
      #     tests = { cuda = { pjrt = linux; } };
      #     gpuCheck = linux;
      #   }
      # Tests keep the attr structure they are defined with, so job paths
      # mirror the tests definitions; [ ] (no platforms) marks a package
      # without any CUDA-requiring test.
      testTree =
        (lib.optionalAttrs (builtins.attrNames (testsTree tests) != [ ]) {
          tests = testsTree tests;
        })
        // topGpuCheck;
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
      testTree
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
      xla.tests.cuda.pjrt = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
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
