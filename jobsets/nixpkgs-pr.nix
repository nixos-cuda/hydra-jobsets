# Jobset that will be triggered on every PR in Nixpkgs.
# We receive 2 Nixpkgs variants: one from target branch (e.g. master), another from the result of merging PR into it.
# We evaluate 4 versions of Nixpkgs per system (with nix-nixpkgs-review):
# - target branch with and without cudaSupport
# - merge commit with and without cudaSupport
# Then we build packages changed by this PR:
# - with cudaSupport, if they are in the cudaPackages set or affected by enabling cudaSupport
# - without cudaSupport
# The `pr-changes` job shows what the PR changed, with and without cudaSupport.
# TODO:
# - add all gpuChecks that are affected by the PR into this jobset
{
  # The platforms supported by the NixOS-CUDA Hydra instance
  supportedSystems ? [
    "x86_64-linux"
    "aarch64-linux"
    # "aarch64-darwin"
  ],
  # The system evaluating this expression
  currentSystem ? "x86_64-linux",

  # Merge commit includes changes in PR, should not trust this
  nixpkgsMerge,
  # Head of the target branch, should be trusted
  nixpkgs,
  targetBranch ? "master",

  # https://github.com/ConnorBaker/nix-nixpkgs-review, which evaluates Nixpkgs and compares the results
  nixNixpkgsReview,
  # The Nix evaluator nixNixpkgsReview's evaluations run with (a `build` input: the tools jobset's iets, for the system
  # Hydra evaluates on)
  iets,
  ...
}@args:

let
  # Used for simple IFDs
  pkgs = import nixpkgs {
    system = currentSystem;
    config = { };
    overlays = [ ];
  };

  ##########################################################
  # STEP 1: Initialize release-lib
  ##########################################################

  lib = import "${nixpkgs}/lib";

  # release-lib.nix provides tools to efficiently map jobs to the actual derivations (packages)
  # it memoizes packages sets for each platform, so we need to have multiple instances
  # for different configs, i.e. with and without CUDA support
  # We use release-lib from the target branch to keep it more stable.
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";
  releaseLibMergeCuda = mkReleaseLib (
    {
      inherit supportedSystems;
      nixpkgsArgs = import ./nixpkgs-pr-args.nix { withCUDA = true; };
      system = currentSystem;
      packageSet = import nixpkgsMerge;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );
  releaseLibMergeNoCuda = mkReleaseLib (
    {
      inherit supportedSystems;
      nixpkgsArgs = import ./nixpkgs-pr-args.nix { withCUDA = false; };
      system = currentSystem;
      packageSet = import nixpkgsMerge;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );

  ##########################################################
  # STEP 2: Compute the set of attrpaths in nixpkgs that are affected by switching cudaSupport from
  # `false` to `true`
  ##########################################################

  supportsCuda = lib.hasSuffix "-linux";
  supportedSystemsWithCuda = lib.filter supportsCuda supportedSystems;

  # mkReport evaluates Nixpkgs in a derivation (read with import-from-derivation), as one JSON line per job; mkJobs
  # compares two (see nix-nixpkgs-review's lib.nix).
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  # The reports, per system: the target branch (head) and merge commit, without and with cudaSupport, e.g.
  # { x86_64-linux = { headNoCuda = <report>; headCuda = <report>; mergeNoCuda = <report>; mergeCuda = <report>; }; }
  # Each is its own derivation, named after its commit and settings, so the target branch's are shared by every PR (and
  # push) with the same target branch commit, and with the CUDA packages jobset (./cuda-packages.nix) for that commit.
  reportsBySystem = lib.genAttrs supportedSystems (
    system:
    let
      mkReport =
        tree: withCUDA:
        nixNixpkgsReviewLib.mkReport {
          inherit tree withCUDA;
          evalSystem = system;
          nixpkgsArgs = ./report-args.nix;
          extraJobs = ./release-extra-jobs.nix;
        };
    in
    {
      headNoCuda = mkReport nixpkgs false;
      mergeNoCuda = mkReport nixpkgsMerge false;
    }
    // lib.optionalAttrs (supportsCuda system) {
      headCuda = mkReport nixpkgs true;
      mergeCuda = mkReport nixpkgsMerge true;
    }
  );

  # What the PR changes, without and with cudaSupport: mkJobs' output, with diff.json and changed.json.
  prBySystem = lib.mapAttrs (
    system: reports:
    {
      prNoCuda = nixNixpkgsReviewLib.mkJobs {
        pre = reports.headNoCuda;
        post = reports.mergeNoCuda;
      };
    }
    // lib.optionalAttrs (supportsCuda system) {
      prCuda = nixNixpkgsReviewLib.mkJobs {
        pre = reports.headCuda;
        post = reports.mergeCuda;
      };
    }
  ) reportsBySystem;

  # Attribute paths of the jobs the PR adds, changes or fixes (that failed to evaluate before) without cudaSupport on a
  # system, e.g. [ [ "blender" ] [ "zigPackages" "0.15" ] ].
  changedPackages = system: lib.importJSON "${prBySystem.${system}.prNoCuda}/changed.json";

  # Attribute paths added, changed or fixed by the PR with cudaSupport, which are also either in one of the cudaPackages
  # sets, only jobs with cudaSupport enabled, or affected by enabling cudaSupport. Only the attributes the PR changed are
  # compared between the reports with and without cudaSupport, rather than diffing the reports in full.
  # jq reads the reports, so that evaluation only reads the (small) result. outputsOf: the outputs of the jobs in a report
  # whose attribute paths (as JSON) are in $want; a path that isn't a job there (it's missing, or failed to evaluate) is
  # null.
  changedCudaPackages =
    system:
    let
      reports = reportsBySystem.${system};
    in
    lib.importJSON (
      pkgs.runCommand "pr-cuda-${system}-cudaPackages" { nativeBuildInputs = [ pkgs.jq ]; } ''
        jq --null-input \
          --slurpfile paths ${prBySystem.${system}.prCuda}/changed.json \
          --slurpfile noCuda ${reports.mergeNoCuda} \
          --slurpfile cuda ${reports.mergeCuda} \
          '
            def outputsOf($want):
              reduce (.[] | select($want[.attrPath | tojson])) as $l ({}; .[$l.attrPath | tojson] = $l.outputs);
            $paths[0] as $paths
            | ($paths | map({ key: tojson, value: true }) | from_entries) as $want
            | ($noCuda | outputsOf($want)) as $noCuda
            | ($cuda | outputsOf($want)) as $cuda
            | $paths
            | map(select((.[0] | startswith("cudaPackages")) or (tojson as $k | $noCuda[$k] != $cuda[$k])))
          ' > "$out"
      ''
    );

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # The jobs, with a cuda or nocuda layer below the system, e.g.
  # { python3Packages.torch = { x86_64-linux.cuda = <drv>; x86_64-linux.nocuda = <drv>; }; }
  releaseJobs = releaseLib: import ./release-jobs.nix { inherit lib releaseLib; };
  prJobs =
    lib.recursiveUpdate
      (releaseJobs releaseLibMergeCuda (job: {
        cuda = job;
      }) supportedSystemsWithCuda changedCudaPackages)
      (releaseJobs releaseLibMergeNoCuda (job: { nocuda = job; }) supportedSystems changedPackages);

  # What the PR adds, changes, removes, breaks and fixes, with and without cudaSupport, shown as a report on the build's
  # page (and as JSON files).
  prChanges =
    pkgs.runCommand "pr-changes" { nativeBuildInputs = [ pkgs.jq ]; }
      # bash
      ''
        mkdir -p "$out/nix-support"
        ${lib.concatStrings (
          lib.mapAttrsToList (
            system: prs:
            lib.concatMapStrings
              (
                { name, label }:
                lib.optionalString (prs ? ${name}) ''
                  install -Dm444 ${prs.${name}}/diff.json "$out/${system}/${name}.json"
                  echo "file json $out/${system}/${name}.json" >> "$out/nix-support/hydra-build-products"
                  {
                    echo "== ${system}, ${label}"
                    jq --raw-output '
                      "\(.added | length) added, \(.changed | length) changed, \(.removed | length) removed, \(.broken | length) broken (no longer evaluate), \(.fixed | length) fixed (evaluate now)",
                      (("added", "changed", "removed", "broken", "fixed") as $k | select(.[$k] != []) | "\n\($k):", (.[$k][] | "  \(join("."))"))
                    ' < ${prs.${name}}/diff.json
                    echo
                  } >> "$out/changes.txt"
                ''
              )
              [
                {
                  name = "prNoCuda";
                  label = "without cudaSupport";
                }
                {
                  name = "prCuda";
                  label = "with cudaSupport";
                }
              ]
          ) prBySystem
        )}
        echo "report changes $out changes.txt" >> "$out/nix-support/hydra-build-products"
      '';

  branchToChannelMap = {
    master = "nixos-unstable-cuda";
    "release-26.05" = "nixos-26.05-cuda";
  };
  channelJobs = import ./cuda-channel/default.nix {
    nixpkgs = nixpkgsMerge;
    channelName = branchToChannelMap.${targetBranch};
    # Same Nixpkgs and config as the PR's CUDA jobs, so evaluator workers share one CUDA package set
    releaseLib = releaseLibMergeCuda;
  };

  # Explicitly specified platforms take precedence over the platforms
  # automatically inferred in autoPackagePlatforms
  jobs =
    if branchToChannelMap ? ${targetBranch} then lib.recursiveUpdate prJobs channelJobs else prJobs;
in
jobs // { pr-changes = prChanges; }
