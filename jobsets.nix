let
  defaults = {
    enabled = 1;
    hidden = false;
    checkinterval = 1800;
    schedulingshares = 1;
    keepnr = 1;
    emailoverride = "";
    nixexprinput = "jobsets";
  };

  inputs = {
    jobsets = {
      type = "git";
      value = "https://github.com/nixos-cuda/hydra-jobsets";
    };
    nixpkgs-unstable = {
      type = "git";
      value = "https://github.com/NixOS/nixpkgs.git nixos-unstable-small";
    };
    nixpkgs-stable = {
      type = "git";
      value = "https://github.com/NixOS/nixpkgs.git nixos-25.11-small";
    };
  };

  jobsetDir = "./jobsets";
  projects = {
    nixos-cuda = {
      cuda-gpu-checks-unstable = defaults // {
        description = "Run GPU Tests";
        nixexprpath = "${jobsetDir}/cuda-tests.nix";
        keepnr = 0;
        inputs = {
          inherit (inputs) jobsets;
          nixpkgs = inputs.nixpkgs-unstable;
        };
      };
      cuda-gpu-checks-stable = defaults // {
        description = "Run GPU Tests [STABLE]";
        nixexprpath = "${jobsetDir}/cuda-tests.nix";
        keepnr = 0;
        inputs = {
          inherit (inputs) jobsets;
          nixpkgs = inputs.nixpkgs-stable;
        };
      };
      cuda-packages-unstable = defaults // {
        description = "All (?) nixpkgs cudaSupport-sensitive packages";
        nixexprpath = "${jobsetDir}/cuda-packages.nix";
        inputs = {
          inherit (inputs) jobsets;
          nixpkgs = inputs.nixpkgs-unstable;
        };
      };
      cuda-packages-stable = defaults // {
        description = "All (?) nixpkgs cudaSupport-sensitive packages [STABLE]";
        nixexprpath = "${jobsetDir}/cuda-packages.nix";
        inputs = {
          inherit (inputs) jobsets;
          nixpkgs = inputs.nixpkgs-stable;
        };
      };
    };
  };
in
{
  projectName,
  declInput,
  nixpkgs,
}:
let
  pkgs = import nixpkgs { };
in
{
  jobsets = (pkgs.writers.writeJSON "jobsets.json" projects.${projectName}).overrideAttrs {
    # Pretty-print the output to logs
    buildCommand = ''
      jq -S . "$valuePath" | tee $out
    '';
  };
}
