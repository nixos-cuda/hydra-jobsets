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

  # "nixos-unstable-cuda", "nixos-25.11-cuda", ...
  channelName,
  ...
}@args:

let
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

  inherit (release-lib)
    forMatchingSystems
    getPlatforms
    hydraJob'
    pkgs
    pkgsFor
    ;
  inherit (lib)
    concatStringsSep
    getAttrFromPath
    groupBy
    head
    mapAttrs
    optionalAttrs
    partition
    pipe
    splitString
    tail
    ;

  channel-blockers = (import ../channel-blockers.nix).${channelName};

  /*
    Map:
    [
      "firefox"
      "opencv"
      "python3Packages.torch"
      "python3Packages.torch.tests.tester-compileCpu.gpuCheck"
    ]

    To:
    {
      firefox.x86_64-linux = <drv>;
      opencv.x86_64-linux = <drv>;
      python3Packages.torch.x86_64-linux = <drv>;
      python3Packages.torch.tests.tester-compileCpu.gpuCheck.x86_64-linux = <drv>;
    }
  */

  groupEntries =
    entries:
    pipe entries [
      /*
        {
          firefox = [ [ "firefox" ] ];
          python3Packages = [
            [ "python3Packages" "torch" ]
            [ "python3Packages" "triton" ]
          ];
        }
      */
      (groupBy head)

      /*
        {
          firefox = [ [] ];
          python3Packages = [
            [ "torch" ]
            [ "triton" ]
          ];
        }
      */
      (mapAttrs (_: map tail))
    ];

  entriesToAttrSet =
    path: entries:
    mapAttrs (
      # python3Packages
      attrName:

      # [ ["torch"] ["torch.tests.gpuCheck"] ["triton"] ]
      entries:
      let
        /*
          {
            right = [];
            wrong = [ ["torch"] ["torch.tests.gpuCheck"] ["triton"] ];
          }
        */
        byLeaf = partition (entry: entry == [ ]) entries;

        # ["python3Packages" "torch" ]
        currentPath = path ++ [ attrName ];

        children = entriesToAttrSet currentPath byLeaf.wrong;

        # pkgs.python3Packages.torch
        package = getAttrFromPath currentPath pkgs;

        /*
          {
            x86_64-linux = <pkgs-x86_64-linux>.python3Packages.torch;
            aarch64-linux = <pkgs-aarch64-linux>.python3Packages.torch;
          };
        */
        packageJobs = forMatchingSystems (getPlatforms package) (
          system:
          let
            # <pkgs-system>.python3Packages.torch;
            pkg = (getAttrFromPath currentPath (pkgsFor system));
          in
          hydraJob' pkg
        );
      in
      children // (optionalAttrs ((builtins.length byLeaf.right) > 0) packageJobs)

    ) (groupEntries entries);

  jobs = (
    pipe channel-blockers [
      # [ [ "python3Packages" "torch" ] [ "firefox" ] ]
      (map (pathStr: splitString "." pathStr))

      (entriesToAttrSet [ ])
    ]
  );

  allJobNames =
    lib.mapAttrsToListRecursiveCond
      # Recurse into non-derivations
      (path: as: !(lib.isDerivation as))

      # Collect all paths
      (path: value: concatStringsSep "." path)

      jobs;

  # Aggregate job that signals that everything passes
  _tested = pkgs.releaseTools.aggregate {
    name = channelName;
    meta = { };
    constituents = allJobNames;
  };
in
jobs // { inherit _tested; }
