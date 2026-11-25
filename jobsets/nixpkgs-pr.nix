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
  lib = import "${nixpkgs}/lib";

  ##########################################################
  # STEP 1: Initialize release-lib
  ##########################################################

  # release-lib memoizes the package sets for each system, so there is one per configuration (with and without CUDA),
  # of the merge commit.
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";
  releaseLibMerge =
    withCUDA:
    mkReleaseLib (
      {
        inherit supportedSystems;
        nixpkgsArgs = import ./nixpkgs-pr-args.nix { inherit withCUDA; };
        system = currentSystem;
        packageSet = import nixpkgsMerge;
      }
      // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
    );
  releaseLibMergeCuda = releaseLibMerge true;
  releaseLibMergeNoCuda = releaseLibMerge false;

  ##########################################################
  # STEP 2: The attribute paths the PR adds, changes or fixes, without and with cudaSupport
  ##########################################################

  supportsCuda = lib.hasSuffix "-linux";
  supportedSystemsWithCuda = lib.filter supportsCuda supportedSystems;

  # The target branch's reports (head) are shared by every PR with the same target branch commit.
  reports = import ./reports.nix {
    inherit
      nixpkgs
      nixNixpkgsReview
      iets
      currentSystem
      ;
  };
  inherit (reports) pkgs;
  reportsOn =
    system: withCUDA:
    let
      report = when: reports.report "${when}${lib.optionalString withCUDA "-cuda"}-${system}";
    in
    {
      head = report "head" nixpkgs system withCUDA;
      merge = report "merge" nixpkgsMerge system withCUDA;
    };

  # What the PR changes, without and with cudaSupport, e.g. { x86_64-linux = { prNoCuda = <mkJobs>; prCuda = ...; }; }
  prBySystem = lib.genAttrs supportedSystems (
    system:
    let
      pr = withCUDA: reports.compare (reportsOn system withCUDA).head (reportsOn system withCUDA).merge;
    in
    { prNoCuda = pr false; } // lib.optionalAttrs (supportsCuda system) { prCuda = pr true; }
  );

  changedPackages = system: reports.changed prBySystem.${system}.prNoCuda;

  # What the PR changes with cudaSupport that is in a cudaPackages set, or that enabling cudaSupport changes in the
  # merge commit (as the CUDA packages jobset finds them).
  changedCudaPackages =
    system:
    let
      sensitive = builtins.listToAttrs (
        map (path: lib.nameValuePair (builtins.toJSON path) true) (
          reports.cudaSensitive (reportsOn system false).merge (reportsOn system true).merge
        )
      );
    in
    lib.filter (
      path: lib.hasPrefix "cudaPackages" (lib.head path) || sensitive ? ${builtins.toJSON path}
    ) (reports.changed prBySystem.${system}.prCuda);

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

  jobs =
    if branchToChannelMap ? ${targetBranch} then lib.recursiveUpdate prJobs channelJobs else prJobs;
in
jobs // { pr-changes = prChanges; }
