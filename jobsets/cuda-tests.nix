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
  # The Nix evaluator nixNixpkgsReview's evaluations run with, built for `currentSystem` (a `build` input: the tools
  # jobset's `iets.<system>`)
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
  # `gpuCheck` (eval/tests.nix there). Its report has every job's attribute path, outputs and `requiredSystemFeatures`.
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  # A report with tests is the most memory-hungry evaluation here: iets can't free what it has evaluated, and with all
  # tests, one process of 8 threads peaked at 31.1 GB (nixpkgs ae2b13d55ef7, x86_64-linux, 25.5 s on 20 aarch64-linux
  # cores). So:
  # - skipTests: the test sets that allocate the most and have no GPU check. With them skipped, the peak was 22.4 GB in
  #   18.9 s, with the same GPU checks found.
  # - workers and maxMemorySize: 4 processes, each replaced once over 4096 MB, so that the report fits in ~16 GB, like
  #   the reports of the other jobsets.
  reports = map (
    system:
    nixNixpkgsReviewLib.mkReport {
      label = "tests-cuda-${system}";
      tree = nixpkgs;
      evalSystem = system;
      withCUDA = true;
      tests = true;
      skipTests = {
        # .NET SDK tests (buildDotnetModule, ...): 1482 tests, a third of the tests' allocations (15.3 GB).
        dotnetCorePackages = true;
        # 205 tests, the next most (6.3 GB).
        azure-cli-extensions = true;
      };
      workers = 4;
      maxMemorySize = 4096;
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
          | select(.requiredSystemFeatures // [] | any(. == "cuda") and all(. != "rocm"))
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
