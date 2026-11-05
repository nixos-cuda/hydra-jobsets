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

  release-lib = mkReleaseLib (
    {
      inherit supportedSystems;
      nixpkgsArgs = import ./nixpkgs-args.nix { withCUDA = true; };
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

  # mkReport evaluates Nixpkgs in a derivation (read with import-from-derivation), as one JSON line per job; mkJobs
  # compares two (see nix-nixpkgs-review's lib.nix).
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  # Test discovery follows the documented Nixpkgs CUDA testing convention (doc/languages-frameworks/cuda.section.md):
  # tests live in `passthru.tests` -- CUDA-specific ones nested, e.g. `tests.cuda.<name>` -- or are a `gpuCheck`, and
  # carry `requiredSystemFeatures = [ "cuda" ]` so they only run on machines exposing a CUDA-capable GPU. Discovery is
  # therefore capability-based: any such test is picked up, whatever it is named, but only within
  # nix-nixpkgs-review's walk of the tests (`passthru.tests` up to three attribute sets deep, and no NixOS tests).
  # Tests requiring `rocm` are skipped: they need an AMD GPU, which the CUDA builders do not have. A `gpuCheck` that
  # fails to evaluate is a job too, so Hydra shows its error.
  #
  # With all tests, a report peaks at about twice the memory of one without (iets can't free what it has evaluated), so:
  # - skipTests: the tests that allocate the most (by eval-jobs' per-job statistics); skipping them leaves out no test
  #   with a `requiredSystemFeatures` of `cuda` (Nixpkgs ae2b13d55ef7);
  # - maxMemorySize: worker processes, each replaced once over 2048 MB, so that the report fits in about the memory of
  #   the other jobsets' reports.
  #
  # The tests' attribute paths, from each system's report, as Hydra names their jobs (without the report's `passthru`),
  # with that system, e.g. { system = "x86_64-linux"; path = [ "blender" "tests" "tester-cudaAvailable" "gpuCheck" ]; }
  # and { system = "x86_64-linux"; path = [ "cudaPackages" "saxpy" "gpuCheck" ]; }. The report is read by jq, so that
  # evaluation only reads the (small) result.
  gpuChecks = lib.concatMap (
    system:
    let
      report = nixNixpkgsReviewLib.mkReport {
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
        nixpkgsArgs = ./gpu-report-args.nix;
      };
    in
    lib.importJSON (
      pkgs.runCommand "gpu-checks-${system}" { nativeBuildInputs = [ pkgs.jq ]; } ''
        jq --slurp --compact-output --arg system ${system} '
          map(
            select(.attrPath | any(. == "passthru"))
            | select(
                if .error then .attrPath[-1] == "gpuCheck"
                else .extraValue.requiredSystemFeatures | any(. == "cuda") and all(. != "rocm") end
              )
            | { $system, path: (.attrPath | index("passthru") as $i | .[:$i] + .[$i + 1:]) }
          )
        ' ${report} > "$out"
      ''
    )
  ) supportedSystems;

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # The tests as a release-lib platform tree, e.g.
  #   {
  #     xla.tests.cuda.pjrt = [ "x86_64-linux" ];
  #     foo.tests.testName.gpuCheck = [ "x86_64-linux" ];
  #   }
  # A path that is a prefix of another (a test that is a job and has a `gpuCheck`) can't be both a leaf and an attribute
  # set: the job is dropped, and its `gpuCheck` kept.
  toTree =
    entries:
    lib.mapAttrs
      (
        _: entries:
        let
          children = lib.filter (entry: entry.path != [ ]) entries;
        in
        if children == [ ] then lib.unique (lib.catAttrs "system" entries) else toTree children
      )
      (
        # Not lib.groupBy', whose lazy fold overflows the stack for a large package set (e.g. python313Packages).
        lib.mapAttrs (_: map (entry: entry // { path = lib.tail entry.path; })) (
          builtins.groupBy (entry: lib.head entry.path) entries
        )
      );

  /*
    {
      foo.tests.testName.gpuCheck.x86_64-linux = <derivation>;
    }
  */
  jobs = release-lib.mapTestOn (toTree gpuChecks);
in
jobs
