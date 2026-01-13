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

  ##########################################################
  # STEP 2: Compute the set of attrpaths in nixpkgs that are affected by switching cudaSupport from
  # `false` to `true`
  ##########################################################

  ci = import "${nixpkgs}/ci" {
    system = currentSystem;
    inherit nixpkgs;
  };

  # TODO: optimize the value of chunkSize for the hydra machine
  evalCudaSupportFalse = ci.eval {
    extraNixpkgsConfig = nixpkgsConfig // {
      cudaSupport = false;
    };
  };
  evalCudaSupportTrue = ci.eval { extraNixpkgsConfig = nixpkgsConfig; };

  # These produce a symlink tree like this:
  # - x86_64-linux
  #   - paths.json
  #   - <other uninteresting stuff>
  # - aarch64-linux
  #   - paths.json
  #   - ...
  #
  # Where paths.json looks like this:
  #
  # {
  #   "AMB-plugins.x86_64-linux": {
  #     "out": "/nix/store/1kfkni7mvz0ak3pkgq38axy6qwfp2kdz-AMB-plugins-0.8.1"
  #   },
  #   "ArchiSteamFarm.x86_64-linux": {
  #     "out": "/nix/store/8lj39bhsxs6hl5whdv6qz280xz71v9i2-ArchiSteamFarm-6.3.1.4"
  #   },
  #   "CuboCore.coreaction.x86_64-linux": {
  #     "out": "/nix/store/zw4wdd4s0qaw24hysqvj1zr150pfr2y9-coreaction-5.0.0"
  #   },
  #   "CuboCore.corearchiver.x86_64-linux": {
  #     "out": "/nix/store/nlr70m9iympiaqzwy07wbpcyh2hkzdc0-corearchiver-5.0.0"
  #   },
  #   ...
  # }

  baselineCudaSupportFalse = evalCudaSupportFalse.baseline { evalSystems = supportedSystems; };
  baselineCudaSupportTrue = evalCudaSupportTrue.baseline { evalSystems = supportedSystems; };

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
        before = getAttrs baselineCudaSupportFalse system;
        after = getAttrs baselineCudaSupportTrue system;
        isAddedOrChanged = name: !(before ? ${name}) || (after.${name} != before.${name});
        addedOrChanged = lib.filter isAddedOrChanged (lib.attrNames after);
      in
      # Cut out "release-checks"
      lib.filter (e: e.path != [ ]) (
        map (pathStr: {
          inherit system;
          path = lib.init (lib.splitString "." pathStr);
        }) addedOrChanged
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

  # Explicitly specified platforms take precedence over the platforms
  # automatically inferred in autoPackagePlatforms
  jobs = release-lib.mapTestOn allPackagePlatforms;
in
jobs
