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

  # What enabling cudaSupport changes, per system (a file). Each diff also depends on every report, so that the first
  # diff evaluation reads (as import-from-derivation) has Nix build all the reports at once, as many in parallel as
  # Hydra's `--max-jobs` (`evaluator_max_jobs`) allows.
  diffs = lib.mapAttrs (
    system: systemReports:
    "${
      nixNixpkgsReviewLib.mkJobs {
        pre = systemReports.noCuda;
        post = systemReports.cuda;
        after = lib.concatMap lib.attrValues (lib.attrValues reports);
      }
    }/diff.json"
  ) reports;

  # The attribute paths added, changed, or fixed (that fail to evaluate without cudaSupport) by enabling cudaSupport on
  # a system, that Hydra builds for it: as Nixpkgs' release.nix does, not those whose `meta.hydraPlatforms` (as the
  # report with cudaSupport has it) leaves the system out. Read by jq, so evaluation only reads the (small) result.
  toBuild =
    system:
    lib.importJSON (
      pkgs.runCommand "cuda-packages-${system}" { nativeBuildInputs = [ pkgs.jq ]; } ''
        jq --null-input --arg system ${system} \
          --slurpfile diff ${diffs.${system}} --slurpfile post ${reports.${system}.cuda} '
            ($post | map(select(.hydraPlatforms) | { key: (.attrPath | tojson), value: .hydraPlatforms }) | from_entries)
              as $hydraPlatforms
            | $diff[0] | .added + .changed + .fixed
            | map(select(tojson as $k | $hydraPlatforms[$k] | . == null or any(. == $system)))
          ' > "$out"
      ''
    );

  # Collect all paths to build into a form of a list:
  # [
  #   {system = "x86_64-linux"; path = ["csxcad"];}
  #   {system = "x86_64-linux"; path = ["ctranslate2"];}
  #   {system = "x86_64-linux"; path = ["cudaPackages" "libcublasmp"];}
  #   {system = "x86_64-linux"; path = ["cudaPackages" "libcudss"];}
  #   {system = "x86_64-linux"; path = ["cudaPackages" "libnvshmem"];}
  #   {system = "x86_64-linux"; path = ["cudaPackages" "nsight_systems"];}
  #   {system = "x86_64-linux"; path = ["cura-appimage"];}
  #   ...
  # ]
  entries = lib.concatMap (
    system: map (path: { inherit system path; }) (toBuild system)
  ) supportedSystems;

  ##########################################################
  # STEP 3: Build the jobset that will be consumed by Hydra
  ##########################################################

  # First, we need to map it to:
  #
  # allPackagePlatforms = {
  #   python3Packages.torch = [ "x86_64-linux" "aarch64-linux" ];
  #   python3Packages.foo = [ "x86_64-linux" ];
  #   python3Packages.bar = [ "aarch64-linux" ];
  #   cool = [ "x86_64-linux" "aarch64-linux" ];
  # }
  #
  # thanks to some nix magic by @MattSturgeon (thanks!)

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

  allPackagePlatforms = entriesToAttrSet entries;

  # release-lib's mapTestOn, without the functions: a report has the derivation a function returns when called with
  # its defaults (e.g. `wrapOBS`), as nix-eval-jobs does, but Nixpkgs' release.nix makes no job of a function.
  inherit (release-lib) forMatchingSystems hydraJob' pkgsFor;
  jobs = lib.mapAttrsRecursive (
    path: systems:
    lib.filterAttrs (_: job: job != null) (
      forMatchingSystems systems (
        system:
        let
          value = lib.getAttrFromPath path (pkgsFor system);
        in
        if lib.isFunction value then null else hydraJob' value
      )
    )
  ) allPackagePlatforms;
in
jobs
