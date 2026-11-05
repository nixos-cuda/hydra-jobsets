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
  # nixpkgs/ci doesn't work on non-Linux platform, so default to Linux while we use it
  currentSystem ? "x86_64-linux",

  # Merge commit includes changes in PR, should not trust this
  nixpkgsMerge,
  # Head of the target branch, should be trusted
  nixpkgs,
  targetBranch ? "master",

  # https://github.com/ConnorBaker/nix-nixpkgs-review, which evaluates Nixpkgs and compares the results
  nixNixpkgsReview,
  # The Nix evaluator nixNixpkgsReview's evaluations run with, built for `currentSystem` (a `build` input: the tools
  # jobset's `iets.<system>`)
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

  # The arguments Nixpkgs is imported with, as a function of { withCUDA, ... }: the same file configures the jobs
  # (through release-lib) and the reports (as nix-nixpkgs-review's `nixpkgsArgs`).
  nixpkgsArgsFile = ./nixpkgs-pr-args.nix;
  nixpkgsArgsFor = withCUDA: import nixpkgsArgsFile { inherit withCUDA; };

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
      nixpkgsArgs = nixpkgsArgsFor true;
      system = currentSystem;
      packageSet = import nixpkgsMerge;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );
  releaseLibMergeNoCuda = mkReleaseLib (
    {
      inherit supportedSystems;
      nixpkgsArgs = nixpkgsArgsFor false;
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

  # nixNixpkgsReview's mkReport evaluates Nixpkgs in a derivation (import-from-derivation) with iets' eval-jobs,
  # recording the output paths of every job, and the error of every attribute that fails to evaluate, without
  # instantiating anything. mkJobs compares two reports: its diff.json lists the attribute paths added, changed,
  # removed, broken and fixed.
  nixNixpkgsReviewLib = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };

  mkReport =
    {
      when,
      tree,
      system,
      withCUDA,
    }:
    after:
    nixNixpkgsReviewLib.mkReport {
      label = "${when}${lib.optionalString withCUDA "-cuda"}-${system}";
      inherit tree withCUDA after;
      evalSystem = system;
      # Evaluate Nixpkgs exactly as release-lib does for the jobs we build
      nixpkgsArgs = nixpkgsArgsFile;
    };

  # Every report uses 8 cores and tens of GB of memory, so each one depends on the one before it and Nix builds them
  # one at a time. Reports for the target branch come first, so they only depend on the target branch and are shared
  # by every PR (and push) with the same target branch commit. In build order: target branch, then merge commit; for
  # each system, without and then with cudaSupport.
  reportSpecs =
    lib.concatMap
      (
        { when, tree }:
        lib.concatMap (
          system:
          map (withCUDA: {
            inherit
              when
              tree
              system
              withCUDA
              ;
          }) ([ false ] ++ lib.optional (supportsCuda system) true)
        ) supportedSystems
      )
      [
        {
          when = "head";
          tree = nixpkgs;
        }
        {
          when = "merge";
          tree = nixpkgsMerge;
        }
      ];

  # [ { when, tree, system, withCUDA, report } ], each report depending on the one before it.
  reports = lib.foldl' (
    previous: spec:
    let
      after = if previous == [ ] then null else (lib.last previous).report;
    in
    previous ++ [ (spec // { report = mkReport spec after; }) ]
  ) [ ] reportSpecs;

  # { x86_64-linux = { headNoCuda = <report>; headCuda = <report>; mergeNoCuda = <report>; mergeCuda = <report>; }; }
  reportsBySystem = lib.genAttrs supportedSystems (
    system:
    lib.listToAttrs (
      map (
        spec: lib.nameValuePair (spec.when + (if spec.withCUDA then "Cuda" else "NoCuda")) spec.report
      ) (lib.filter (spec: spec.system == system) reports)
    )
  );

  # The diff of two reports (a file). Each also depends on the last report, so that the first of them evaluation asks
  # for (as import-from-derivation) has all the reports built one after the other, rather than the reports it doesn't
  # need waiting for it and its queries to be built.
  mkDiff =
    pre: post:
    "${
      nixNixpkgsReviewLib.mkJobs {
        inherit pre post;
        after = (lib.last reports).report;
      }
    }/diff.json";

  diffsBySystem = lib.mapAttrs (
    system: reports:
    {
      # What the PR changes without cudaSupport
      prNoCuda = mkDiff reports.headNoCuda reports.mergeNoCuda;
    }
    // lib.optionalAttrs (supportsCuda system) {
      # What the PR changes with cudaSupport
      prCuda = mkDiff reports.headCuda reports.mergeCuda;
    }
  ) reportsBySystem;

  # Runs jq over reports and diffs (each available as `$<name>`, an array of its JSON values: a diff is one value, a
  # report one per line), so evaluator workers only read the (small) result.
  query =
    name: inputs: filter:
    lib.importJSON (
      pkgs.runCommand name { nativeBuildInputs = [ pkgs.jq ]; } ''
        jq --null-input ${
          lib.concatStringsSep " " (lib.mapAttrsToList (input: path: "--slurpfile ${input} ${path}") inputs)
        } ${lib.escapeShellArg filter} > "$out"
      ''
    );

  # Attribute paths of the jobs a diff adds, changes or fixes (that failed to evaluate before), e.g.
  # [ [ "blender" ] [ "zigPackages" "0.15" ] ].
  toBuild =
    diff:
    let
      inherit (lib.importJSON diff) added changed fixed;
    in
    added ++ changed ++ fixed;

  # Attribute paths added, changed or fixed by the PR with cudaSupport, which are also either in one of the
  # cudaPackages sets, only jobs with cudaSupport enabled, or affected by enabling cudaSupport. Only the attributes the
  # PR changed are compared between the reports with and without cudaSupport, rather than diffing the reports in full.
  changedCudaPackages =
    system:
    let
      reports = reportsBySystem.${system};
    in
    query "pr-cuda-${system}-cudaPackages"
      {
        pr = diffsBySystem.${system}.prCuda;
        noCuda = reports.mergeNoCuda;
        cuda = reports.mergeCuda;
      }
      # outputsOf: the outputs of the jobs in a report whose attribute paths (as JSON) are in $want; a path that isn't a
      # job there (it's missing, or failed to evaluate) is null.
      ''
        def outputsOf($want):
          reduce (.[] | select($want[.attrPath | tojson])) as $l ({}; .[$l.attrPath | tojson] = $l.outputs);
        ($pr[0] | .added + .changed + .fixed) as $paths
        | ($paths | map({ key: tojson, value: true }) | from_entries) as $want
        | ($noCuda | outputsOf($want)) as $noCuda
        | ($cuda | outputsOf($want)) as $cuda
        | $paths
        | map(select((.[0] | startswith("cudaPackages")) or (tojson as $k | $noCuda[$k] != $cuda[$k])))
      '';

  toEntries =
    system:
    map (path: {
      inherit system path;
    });

  # Collect all paths that changed between these into a form of a list:
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
  entriesCuda = lib.concatMap (
    system: toEntries system (changedCudaPackages system)
  ) supportedSystemsWithCuda;

  # Packages added, changed or fixed by this PR without cudaSupport
  entriesNoCuda = lib.concatMap (
    system: toEntries system (toBuild diffsBySystem.${system}.prNoCuda)
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
  # Then apply testOn and add cuda/nocuda suffixes to bring it to:
  #
  # prJobs = {
  #   python3Packages.torch = { "x86_64-linux".cuda: <drv>; "aarch64-linux".cuda: <drv>; };
  #   python3Packages.foo = { "x86_64-linux".nocuda: <drv>; };
  #   python3Packages.bar = { "aarch64-linux".cuda: <drv>; };
  #   cool = { "x86_64-linux".nocuda: <drv>; "aarch64-linux".nocuda: <drv>; };
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

  # Like mapTestOn, only adds one more attrset layer, so that we can
  # distinguish builds with and without CUDA support
  mapTestOnWithSuffix =
    releaseLib: suffix:
    let
      inherit (releaseLib) forMatchingSystems hydraJob' pkgsFor;
    in
    lib.mapAttrsRecursive (
      #path: metaPatterns: releaseLib.testOn metaPatterns (pkgs: lib.getAttrFromPath path pkgs)
      path: metaPatterns:
      forMatchingSystems metaPatterns (system: {
        ${suffix} = hydraJob' (lib.getAttrFromPath path (pkgsFor system));
      })
    );

  prJobsCuda = mapTestOnWithSuffix releaseLibMergeCuda "cuda" (entriesToAttrSet entriesCuda);
  prJobsNoCuda = mapTestOnWithSuffix releaseLibMergeNoCuda "nocuda" (entriesToAttrSet entriesNoCuda);
  prJobs = lib.recursiveUpdate prJobsCuda prJobsNoCuda;

  # What the PR adds, changes, removes, breaks and fixes, with and without cudaSupport, shown as a report on the build's
  # page (and as JSON files).
  prChanges =
    pkgs.runCommand "pr-changes" { nativeBuildInputs = [ pkgs.jq ]; }
      # bash
      ''
        mkdir -p "$out/nix-support"
        ${lib.concatStrings (
          lib.mapAttrsToList (
            system: diffs:
            lib.concatMapStrings
              (
                { name, label }:
                lib.optionalString (diffs ? ${name}) ''
                  install -Dm444 ${diffs.${name}} "$out/${system}/${name}.json"
                  echo "file json $out/${system}/${name}.json" >> "$out/nix-support/hydra-build-products"
                  {
                    echo "== ${system}, ${label}"
                    jq --raw-output '
                      "\(.added | length) added, \(.changed | length) changed, \(.removed | length) removed, \(.broken | length) broken (no longer evaluate), \(.fixed | length) fixed (evaluate now)",
                      (("added", "changed", "removed", "broken", "fixed") as $k | select(.[$k] != []) | "\n\($k):", (.[$k][] | "  \(join("."))"))
                    ' < ${diffs.${name}}
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
          ) diffsBySystem
        )}
        echo "report changes $out changes.txt" >> "$out/nix-support/hydra-build-products"
      '';

  branchToChannelMap = {
    master = "nixos-unstable-cuda";
    "release-26.05" = "nixos-26.05-cuda";
  };
  channelJobs = import ./cuda-channel/default.nix {
    inherit currentSystem;
    supportedSystems = supportedSystemsWithCuda;
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
