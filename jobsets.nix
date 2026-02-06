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

  nixpkgsChannelNames = {
    unstable = "nixos-unstable-small";
    "25.11" = "nixos-25.11-small";
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
      "cuda-gpu-checks-25.11" = {
        description = "Run GPU Tests";
        definitionFile = "cuda-tests.nix";
        nixpkgsRelease = "25.11";
      };

      # PACKAGES
      cuda-packages-unstable = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "unstable";
      };
      "cuda-packages-25.11" = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "25.11";
      };

      # CHANNELS
      channel-unstable = {
        description = "Channel blockers";
        definitionFile = "cuda-channel.nix";
        nixpkgsRelease = "unstable";
        extraInputs.channelName = {
          type = "string";
          value = "nixos-unstable-cuda";
        };
      };
      "channel-25.11" = {
        description = "Channel blockers";
        definitionFile = "cuda-channel.nix";
        nixpkgsRelease = "25.11";
        extraInputs.channelName = {
          type = "string";
          value = "nixos-25.11-cuda";
        };
      };
    };
  };
in
projects
