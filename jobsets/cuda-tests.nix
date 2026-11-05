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

  # https://github.com/ConnorBaker/nix-nixpkgs-review, which evaluates Nixpkgs and its tests
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
  # (through release-lib) and the report (as nix-nixpkgs-review's `nixpkgsArgs`).
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
  # STEP 2: Find the GPU checks
  ##########################################################

  # Used for simple IFDs
  pkgs = import nixpkgs {
    system = currentSystem;
    config = { };
    overlays = [ ];
  };

  # nixNixpkgsReview's mkReport evaluates Nixpkgs in a derivation (import-from-derivation) with iets' eval-jobs. With
  # `tests`, it also walks every package's tests: its `passthru.tests`, its `passthru.gpuCheck`, and each test's
  # `gpuCheck` (eval/tests.nix there). `apply` adds each job's `requiredSystemFeatures` to the report.
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  # With all tests, a report peaks at about twice the memory of one without (iets can't free what it has evaluated), so:
  # - skipTests: the tests that allocate the most, none of which needs a GPU;
  # - maxMemorySize: worker processes, each replaced once over 2048 MB, so that the report fits in about the memory of
  #   the other jobsets' reports.
  # nix-nixpkgs-review's README ("Cost") has the measurements.
  reports = map (
    system:
    nixNixpkgsReviewLib.mkReport {
      label = "tests-cuda-${system}";
      tree = nixpkgs;
      evalSystem = system;
      withCUDA = true;
      tests = true;
      skipTests = {
        dotnetCorePackages = true;
        azure-cli-extensions = true;
      };
      maxMemorySize = 2048;
      apply = "drv: { requiredSystemFeatures = drv.requiredSystemFeatures or [ ]; }";
      nixpkgsArgs = nixpkgsArgsFile;
    }
  ) supportedSystems;

  # Test discovery follows the documented Nixpkgs CUDA testing convention (doc/languages-frameworks/cuda.section.md):
  # tests live in `passthru.tests` -- CUDA-specific ones nested, e.g. `tests.cuda.<name>` -- or are a `gpuCheck`, and
  # carry `requiredSystemFeatures = [ "cuda" ]` so they only run on machines exposing a CUDA-capable GPU. Discovery is
  # therefore capability-based: any such test is picked up, whatever it is named. Tests requiring `rocm` are skipped:
  # they need an AMD GPU, which the CUDA builders do not have.
  #
  # The attribute paths of these tests, from every report, as Hydra names their jobs: without the report's `passthru`,
  # e.g. [ "blender" "tests" "tester-cudaAvailable" "gpuCheck" ] and [ "cudaPackages" "saxpy" "gpuCheck" ]. The report
  # is read by jq, so that evaluation only reads the (small) result.
  gpuChecks = lib.importJSON (
    pkgs.runCommand "gpu-checks" { nativeBuildInputs = [ pkgs.jq ]; } ''
      jq --null-input --compact-output '
        [ inputs
          | select(.attrPath | any(. == "passthru"))
          | select(.extraValue.requiredSystemFeatures // [] | any(. == "cuda") and all(. != "rocm"))
          | .attrPath
          | index("passthru") as $i
          | .[:$i] + .[$i + 1:]
        ]
        | unique
      ' ${lib.escapeShellArgs reports} > "$out"
    ''
  );

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  groupEntries = lib.groupBy' (paths: path: paths ++ [ (lib.tail path) ]) [ ] lib.head;

  # The tests as a release-lib platform tree, e.g.
  #   {
  #     xla.tests.cuda.pjrt = [ "x86_64-linux" ];
  #     foo.tests.testName.gpuCheck = [ "x86_64-linux" ];
  #   }
  # A path that is a prefix of another (a test that is a job and has a `gpuCheck`) can't be both a leaf and an attribute
  # set: the job is dropped, and its `gpuCheck` kept.
  pathsToTree =
    paths:
    lib.mapAttrs (
      _: rests:
      let
        children = lib.filter (rest: rest != [ ]) rests;
      in
      if children == [ ] then supportedSystems else pathsToTree children
    ) (groupEntries paths);

  /*
    {
      foo.tests.testName.gpuCheck.x86_64-linux = <derivation>;
    }
  */
  jobs = release-lib.mapTestOn (pathsToTree gpuChecks);
in
jobs
