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

      flake.jobsets = {
        cuda-packages = import ./jobsets/cuda-packages.nix { inherit nixpkgs; };
        cuda-tests = import ./jobsets/cuda-tests.nix { inherit nixpkgs; };
      };
    };
}
