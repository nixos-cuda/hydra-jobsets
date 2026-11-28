let
  defaults = {
    enabled = 1;
    hidden = false;
    checkinterval = 1800;
    schedulingshares = 1;

    # Number of past eval results to keep.
    # The older ones will be garbage collected.
    keepnr = 500;
    emailoverride = "";
    nixexprinput = "jobsets";
  };

  nixpkgsChannelNames = {
    unstable = "nixos-unstable-small";
    "26.05" = "nixos-26.05-small";
    "26.11" = "nixos-26.11-small";
  };

  mkJobset =
    {
      nixpkgsRelease,
      description,
      definitionFile,
      extraInputs ? { },
    }:
    let
      nixpkgsChannelName = nixpkgsChannelNames.${nixpkgsRelease};
    in
    defaults
    // {
      description = "${description} [${nixpkgsChannelName}]";
      nixexprpath = "./jobsets/${definitionFile}";

      inputs = {
        jobsets = {
          type = "git";
          value = "https://github.com/nixos-cuda/hydra-jobsets";
        };

        nixpkgs = {
          type = "git";
          value = "https://github.com/NixOS/nixpkgs.git ${nixpkgsChannelName}";
        };
      }
      // extraInputs;
    };

  projects = {
    nixos-cuda = builtins.mapAttrs (_: mkJobset) {
      # GPU CHECKS
      cuda-gpu-checks-unstable = {
        description = "Run GPU Tests";
        definitionFile = "cuda-tests.nix";
        nixpkgsRelease = "unstable";
      };
      "cuda-gpu-checks-26.05" = {
        description = "Run GPU Tests";
        definitionFile = "cuda-tests.nix";
        nixpkgsRelease = "26.05";
      };
      "cuda-gpu-checks-26.11" = {
        description = "Run GPU Tests";
        definitionFile = "cuda-tests.nix";
        nixpkgsRelease = "26.11";
      };

      # PACKAGES
      cuda-packages-unstable = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "unstable";
      };
      "cuda-packages-26.05" = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "26.05";
      };
      "cuda-packages-26.11" = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "26.11";
      };

      # CHANNELS
      channel-unstable = {
        description = "Channel blockers";
        definitionFile = "cuda-channel/default.nix";
        nixpkgsRelease = "unstable";
        extraInputs.channelName = {
          type = "string";
          value = "nixos-unstable-cuda";
        };
      };
      "channel-26.05" = {
        description = "Channel blockers";
        definitionFile = "cuda-channel/default.nix";
        nixpkgsRelease = "26.05";
        extraInputs.channelName = {
          type = "string";
          value = "nixos-26.05-cuda";
        };
      };
      "channel-26.11" = {
        description = "Channel blockers";
        definitionFile = "cuda-channel/default.nix";
        nixpkgsRelease = "26.11";
        extraInputs.channelName = {
          type = "string";
          value = "nixos-26.11-cuda";
        };
      };
    };
  };

  # Builds iets, the Nix evaluator nixpkgs PR jobsets evaluate Nixpkgs with (through
  # nix-nixpkgs-review; consumed as a `build` input, see the nixos-cuda/infra hydra-github-app
  # template).
  tools = defaults // {
    description = "Tools used by other jobsets";
    type = 1;
    flake = "github:ConnorBaker/nix-nixpkgs-review";
    inputs = { };
  };
in
projects
// {
  nixos-cuda = projects.nixos-cuda // {
    inherit tools;
  };
}
