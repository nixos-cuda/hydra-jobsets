# Jobset that will be triggered on every PR in Nixpkgs.
# We receive 2 Nixpkgs variants: one from target branch (e.g. master), another from the result of merging PR into it.
# We evaluate 3 versions of Nixpkgs:
# - target branch with and without cudaSupport
# - merge commit with cudaSupport
# Then we collect only packages that are changed by this PR and are affected by enabling cudaSupport.
# TODO:
# - add all gpuChecks that are affected by the PR into this jobset
{
  # The platforms supported by the NixOS-CUDA Hydra instance
  supportedSystems ? [
    "x86_64-linux"
    # "aarch64-linux"
  ],
  # The system evaluating this expression
  # nixpkgs/ci doesn't work on non-Linux platform, so default to Linux while we use it
  currentSystem ? "x86_64-linux",

  # Merge commit includes changes in PR, should not trust this
  nixpkgsMerge,
  # Head of the target branch, should be trusted
  nixpkgs,
  targetBranch ? "master",
  ...
}@args:

let
  # Used for simple IFDs
  pkgs = import nixpkgs {
    system = currentSystem;
    config = { };
    overlays = [ ];
  };

  # Ignore these known vulnerabilities for CI:
  # - tensorrt:
  #   - [CVE-2026-24188](https://github.com/NixOS/nixpkgs/issues/522570): OOB write
  # - vllm:
  #   - https://github.com/vllm-project/vllm/security/advisories/GHSA-7972-pg2x-xr59 (CVE-2026-27893)
  #   - https://github.com/vllm-project/vllm/security/advisories/GHSA-83vm-p52w-f9pw (CVE-2026-44223)
  #   - https://github.com/vllm-project/vllm/security/advisories/GHSA-hpv8-x276-m59f (CVE-2026-44222)
  # Can't use allowInsecurePredicate because Nixpkgs ci/eval needs the config to be serializable to JSON
  patchInsecurePackages =
    nixpkgsTree:
    pkgs.runCommand "patch-nixpkgs" { } ''
      cp -r ${nixpkgsTree} $out
      substituteInPlace $out/pkgs/development/cuda-modules/packages/tensorrt.nix \
        --replace-warn '"CVE-2026-24188: OOB write"' '''
      substituteInPlace $out/pkgs/development/python-modules/vllm/default.nix \
        --replace-warn '"CVE-2026-27893"' ''' \
        --replace-warn '"CVE-2026-44223"' ''' \
        --replace-warn '"CVE-2026-44222"' '''
    '';
  nixpkgs' = patchInsecurePackages nixpkgs;
  nixpkgsMerge' = patchInsecurePackages nixpkgsMerge;

  ##########################################################
  # STEP 1: Initialize release-lib
  ##########################################################

  lib = import "${nixpkgs'}/lib";

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

  # release-lib.nix provides tools to efficiently map jobs to the actual derivations (packages)
  # it memoizes packages sets for each platform, so we need to have multiple instances
  # for different configs, i.e. with and without CUDA support
  # We use release-lib from the target branch to keep it more stable.
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";
  releaseLibMergeCuda = mkReleaseLib (
    {
      inherit supportedSystems nixpkgsArgs;
      system = currentSystem;
      packageSet = import nixpkgsMerge';
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );

  ##########################################################
  # STEP 2: Compute the set of attrpaths in nixpkgs that are affected by switching cudaSupport from
  # `false` to `true`
  ##########################################################

  ciMerge = import "${nixpkgsMerge'}/ci" {
    system = currentSystem;
    nixpkgs = nixpkgsMerge';
  };

  ciHead = import "${nixpkgs'}/ci" {
    system = currentSystem;
    nixpkgs = nixpkgs';
  };

  # TODO: optimize the value of chunkSize for the hydra machine
  baseline =
    ci: withCuda:
    (ci.eval {
      extraNixpkgsConfig = if withCuda then nixpkgsConfig else nixpkgsConfig // { cudaSupport = false; };
    }).baseline
      { evalSystems = supportedSystems; };

  baselines = pkgs.linkFarm "baselines" {
    headCuda = baseline ciHead true;
    mergeCuda = baseline ciMerge true;
    mergeNoCuda = baseline ciHead false;
  };

  # Taken from ci/eval/diff.nix
  getAttrs =
    dir: evalSystem:
    let
      raw = builtins.readFile "${dir}/${evalSystem}/paths.json";
      # The file contains Nix paths; we need to ignore them for evaluation purposes,
      # else there will be a "is not allowed to refer to a store path" error.
      data = builtins.unsafeDiscardStringContext raw;
    in
    builtins.fromJSON data;

  # Cache attrs for each package set + config + system
  # { "x86_64-linux": { headCuda = ...; mergeCuda = ...; mergeNoCuda = ...; }; }
  attrs = lib.genAttrs supportedSystems (
    system:
    lib.genAttrs [
      "headCuda"
      "mergeCuda"
      "mergeNoCuda"
    ] (name: getAttrs "${baselines}/${name}" system)
  );

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

  entries = lib.concatLists (
    lib.forEach supportedSystems (
      system:
      let
        inherit (attrs.${system})
          headCuda
          mergeCuda
          mergeNoCuda
          ;
        predicate =
          name:
          # Package must be added or changed in this PR
          (!(headCuda ? ${name}) || (mergeCuda.${name} != headCuda.${name}))
          # And must be one of:
          && (
            # in one of cudaPackages sets
            (lib.hasPrefix "cudaPackages" name)
            # only present with cudaSupport enabled
            || !(mergeNoCuda ? ${name})
            # affected by enabling cudaSupport
            || (mergeCuda.${name} != mergeNoCuda.${name})
          );
        filtered = lib.filter predicate (lib.attrNames mergeCuda);
      in
      # Cut out "release-checks"
      lib.filter (e: e.path != [ ]) (
        map (pathStr: {
          inherit system;
          path = lib.init (lib.splitString "." pathStr);
        }) filtered
      )
    )
  );

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

  prJobs = releaseLibMergeCuda.mapTestOn allPackagePlatforms;
  branchToChannelMap = {
    master = "nixos-unstable-cuda";
    "release-26.05" = "nixos-26.05-cuda";
  };
  channelJobs = import ./cuda-channel/default.nix {
    inherit supportedSystems currentSystem;
    nixpkgs = nixpkgsMerge';
    channelName = branchToChannelMap.${targetBranch};
  };

  # Explicitly specified platforms take precedence over the platforms
  # automatically inferred in autoPackagePlatforms
  jobs =
    if branchToChannelMap ? ${targetBranch} then lib.recursiveUpdate prJobs channelJobs else prJobs;
in
jobs
