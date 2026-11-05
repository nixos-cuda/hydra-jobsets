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

  # "nixos-unstable-cuda", "nixos-26.05-cuda", ...
  channelName,

  # An existing release-lib instance for `nixpkgs`, whose package sets are then shared: the PR jobset passes its CUDA
  # jobs' (configured by ../nixpkgs-pr-args.nix, not ../nixpkgs-args.nix).
  releaseLib ? null,
  ...
}@args:

let
  lib = import "${nixpkgs}/lib";
  mkReleaseLib = import "${nixpkgs}/pkgs/top-level/release-lib.nix";

  release-lib =
    if releaseLib != null then
      releaseLib
    else
      mkReleaseLib (
        {
          inherit supportedSystems;
          nixpkgsArgs = import ../nixpkgs-args.nix { withCUDA = true; };
          system = currentSystem;
        }
        // lib.intersectAttrs (lib.functionArgs mkReleaseLib) args
      );

  inherit (release-lib) pkgs;
  inherit (lib) concatStringsSep isDerivation;

  jobsFromChannelBlockers = import ./jobs-from-channel-blockers.nix {
    inherit
      lib
      release-lib
      channelName
      ;
    channelBlockers = (import ../../channel-blockers.nix).${channelName};
  };

  jobs = jobsFromChannelBlockers;

  allJobNames =
    lib.mapAttrsToListRecursiveCond
      # Recurse into non-derivations
      (path: as: !(isDerivation as))

      # Collect all paths
      (path: value: concatStringsSep "." path)

      jobs;

  # Aggregate job that signals that everything passes
  _tested = pkgs.releaseTools.aggregate {
    name = "${channelName}-${nixpkgs.revision or nixpkgs.rev or nixpkgs.shortRev or "unknown"}";
    meta = { };
    constituents = allJobNames;
  };
in
jobs // { inherit _tested; }
