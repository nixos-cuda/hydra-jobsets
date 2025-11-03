{
  # The platforms for which we build Nixpkgs.
  supportedSystems ? [
    "x86_64-linux"
    # "aarch64-linux"
  ],

  nixpkgs,

  # Attributes passed to nixpkgs.
  cudaLib ? (import "${nixpkgs}/pkgs/development/cuda-modules/_cuda").lib,
  nixpkgsArgs ? {
    config = {
      # TODO
      allowUnfreePredicate = cudaLib.allowUnfreeCudaPredicate;
      cudaSupport = true;
      inHydra = true;

      # Don't evaluate duplicate and/or deprecated attributes
      allowAliases = false;
    };

    __allowFileset = false;
  },
  ...
}@args:

let
  # TODO
  system = "x86_64-linux";

  lib = import "${nixpkgs}/lib";
  # cudaLib = (import "${nixpkgs}/pkgs/development/cuda-modules/_cuda").lib;
  # evalResult = builtins.fromJSON (
  #   import ./generate-jobset.nix {
  #     inherit system evalSystems;
  #     inherit (packageSet) callPackage;
  #   }
  # );
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";
  release-lib = mkReleaseLib (
    {
      inherit supportedSystems nixpkgsArgs system;
    }
    // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
  );

  inherit (release-lib)
    linux
    mapTestOn
    packagePlatforms
    pkgs
    ;

  evalResultOut = import ./generate-jobset.nix {
    inherit pkgs nixpkgs;
    evalSystems = supportedSystems;
  };

  inherit (lib.importJSON evalResultOut) rebuildsByPlatform;

  # Previous manual mapping declared in pkgs/top-level/release-cuda.nix
  # allPackagePlatforms = {
  #   blas = linux;
  #   blender = linux;
  #   python3Packages.torch = linux;
  # };

  allPackagePlatforms = lib.foldlAttrs (
    acc: system:
    let
      foldPaths = lib.foldl (
        acc: str:
        let
          res = lib.setAttrByPath (lib.splitString "." str) system;
        in
        lib.recursiveUpdate acc res
      );
    in
    foldPaths acc
  ) { } rebuildsByPlatform;

  # We need to go from
  # rebuildsByPlatform = {
  #   "x86_64-linux" = [
  #     "python3Packages.torch"
  #     "python3Packages.foo"
  #     "cool"
  #   ];
  #   "aarch64-linux" = [
  #     "python3Packages.torch"
  #     "python3Packages.bar"
  #     "cool"
  #   ];
  # }
  # to:
  # {
  #   python3Packages.torch = [ "x86_64-linux" "aarch64-linux" ];
  #   python3Packages.foo = [ "x86_64-linux" ];
  #   python3Packages.bar = [ "aarch64-linux" ];
  #   cool = [ "x86_64-linux" "aarch64-linux" ];
  # }
  # Then, we can feed this to mapTestOn

  # Explicitly specified platforms take precedence over the platforms
  # automatically inferred in autoPackagePlatforms
  jobs = mapTestOn allPackagePlatforms;
in
lib.generators.toPretty { } jobs
# lib.generators.toPretty { } rebuildsByPlatform
# rebuildsJSON
# allPackagePlatforms
