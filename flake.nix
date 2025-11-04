{
  description = "CUDA Hydra jobset generator";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
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

      flake.jobset = import ./jobset.nix {
        inherit nixpkgs;
      };
      perSystem =
        { pkgs, system, ... }:
        {
          packages.default = pkgs.callPackage ./generate-jobset.nix { inherit nixpkgs system; };
        };
    };
}
