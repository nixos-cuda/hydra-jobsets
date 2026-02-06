{
  description = "CUDA Hydra jobset generator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    git-hooks-nix = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      flake-parts,
      nixpkgs,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      imports = [
        inputs.git-hooks-nix.flakeModule
      ];

      flake.jobsets = {
        cuda-packages = import ./jobsets/cuda-packages.nix { inherit nixpkgs; };
        cuda-tests = import ./jobsets/cuda-tests.nix { inherit nixpkgs; };
        cuda-channel = import ./jobsets/cuda-channel.nix {
          inherit nixpkgs;
          channelName = "nixos-unstable-cuda";
        };
      };

      perSystem =
        { system, ... }:
        {
          pre-commit.settings.hooks = {
            actionlint.enable = true;
            nixfmt.enable = true;
          };
          checks =
            let
              projects = import ./jobsets.nix;
              declarativeJobsets = import ./declarative-jobsets.nix;
              jobsetsForProjects = nixpkgs.lib.genAttrs (nixpkgs.lib.attrNames projects) (
                projectName:
                (declarativeJobsets {
                  inherit projectName nixpkgs system;
                  declInput = { };
                }).jobsets
              );
            in
            jobsetsForProjects;
        };
    };
}
