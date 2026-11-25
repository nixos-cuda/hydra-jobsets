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
  };

  # What the jobsets that evaluate Nixpkgs with nix-nixpkgs-review take: its library, and iets, the evaluator its
  # reports run, built by the `tools` jobset below for the system Hydra evaluates on.
  nixNixpkgsReviewInputs = {
    nixNixpkgsReview = {
      type = "git";
      value = "https://github.com/ConnorBaker/nix-nixpkgs-review";
    };
    iets = {
      type = "build";
      value = "nixos-cuda:tools:iets.x86_64-linux";
    };
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
    nixos-cuda = {
      # Builds iets, the Nix evaluator the jobsets evaluate Nixpkgs with (through nix-nixpkgs-review), as the `iets`
      # build input of those above and of the nixpkgs PR jobsets (see the nixos-cuda/infra hydra-github-app template).
      tools = defaults // {
        description = "Tools used by other jobsets";
        type = 1;
        flake = "github:ConnorBaker/nix-nixpkgs-review";
        inputs = { };
      };
    }
    // builtins.mapAttrs (_: mkJobset) {
      # GPU CHECKS
      cuda-gpu-checks-unstable = {
        description = "Run GPU Tests";
        definitionFile = "cuda-tests.nix";
        nixpkgsRelease = "unstable";
        extraInputs = nixNixpkgsReviewInputs;
      };
      "cuda-gpu-checks-26.05" = {
        description = "Run GPU Tests";
        definitionFile = "cuda-tests.nix";
        nixpkgsRelease = "26.05";
        extraInputs = nixNixpkgsReviewInputs;
      };

      # PACKAGES
      cuda-packages-unstable = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "unstable";
        extraInputs = nixNixpkgsReviewInputs;
      };
      "cuda-packages-26.05" = {
        description = "All nixpkgs cudaSupport-sensitive packages";
        definitionFile = "cuda-packages.nix";
        nixpkgsRelease = "26.05";
        extraInputs = nixNixpkgsReviewInputs;
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
    };
  };
in
projects
