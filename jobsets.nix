let
  defaults = {
    enabled = 1;
    hidden = false;
    checkinterval = 1800;
    schedulingshares = 1;
    keepnr = 1;
    emailoverride = "";
  };
  projects = {
    nixos-cuda = {
      cuda-gpu-checks-unstable = defaults // {
        description = "Run GPU Tests";
        nixexprinput = "jobsets";
        nixexprpath = "cuda-tests.nix";
        keepnr = 0;
        inputs = {
          jobsets = {
            type = "git";
            value = "https://github.com/nixos-cuda/hydra-jobsets";
          };
          nixpkgs = {
            type = "git";
            value = "https://github.com/NixOS/nixpkgs.git nixos-unstable-small";
          };
        };
      };
      cuda-gpu-checks-stable = defaults // {
        description = "Run GPU Tests [STABLE]";
        nixexprinput = "jobsets";
        nixexprpath = "cuda-tests.nix";
        keepnr = 0;
        inputs = {
          jobsets = {
            type = "git";
            value = "https://github.com/nixos-cuda/hydra-jobsets";
          };
          nixpkgs = {
            type = "git";
            value = "https://github.com/NixOS/nixpkgs.git nixos-25.11-small";
          };
        };
      };
      cuda-packages-unstable = defaults // {
        description = "All (?) nixpkgs cudaSupport-sensitive packages";
        nixexprinput = "jobsets";
        nixexprpath = "cuda-packages.nix";
        inputs = {
          nixpkgs = {
            type = "git";
            value = "https://github.com/NixOS/nixpkgs.git nixos-unstable-small";
          };
          jobsets = {
            type = "git";
            value = "https://github.com/nixos-cuda/hydra-jobsets";
          };
        };
      };
      cuda-packages-stable = defaults // {
        description = "All (?) nixpkgs cudaSupport-sensitive packages [STABLE]";
        nixexprinput = "jobsets";
        nixexprpath = "cuda-packages.nix";
        inputs = {
          nixpkgs = {
            value = "https://github.com/NixOS/nixpkgs.git nixos-25.11-small";
            type = "git";
          };
          jobsets = {
            type = "git";
            value = "https://github.com/nixos-cuda/hydra-jobsets";
          };
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
