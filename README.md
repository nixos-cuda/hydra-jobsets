# NixOS-CUDA Hydra jobsets

This repository hosts the definitions of the jobsets running on the
[NixOS-CUDA Hydra instance](https://hydra.nixos-cuda.org/project/nixos-cuda).

## Upstream nixpkgs channels

All jobsets come in both an _unstable_ and a _stable_ flavor.
The corresponding upstream nixpkgs channels used are
`nixos-unstable-small` and `nixos-25.11-small`, respectively.

## Declarative jobsets

The jobsets configurations themselves are explicitly stored in this repo as well.
Indeed, we use the [declarative projects](https://hydra.nixos.org/build/320151937/download/1/hydra/plugins/declarative-projects.html) feature of Hydra.

- [`jobsets-spec.json`](./jobsets-spec.json) (the _declarative spec file_) configures the `.jobsets` jobset.
- [`jobsets.nix`](./jobsets.nix) defines the `jobsets` job (part of the `.jobsets` jobset) which generates the other jobsets.

The [`nixos-cuda` project](https://hydra.nixos-cuda.org/project/nixos-cuda) on Hydra pulls those files to configure the jobsets.

## Jobsets

### CUDA packages

- **jobsets:** `cuda-packages-[un]stable`
- **definition file:** [./jobsets/cuda-packages.nix](./jobsets/cuda-packages.nix)
- **Content:** All `cudaSupport`-sensitive nixpkgs packages (~2k packages).\
  More specifically, we leverage
  [nixpkgs' CI evaluation logic](https://github.com/NixOS/nixpkgs/tree/master/ci/eval)
  to compute the set of packages whose hash changes when `cudaSupport` is enabled.
- **Purpose:** Ensure packages build correctly with CUDA features enabled.\
  While distributing the build artifacts of some NVIDIA products is not allowed
  by their license, the results from this jobset populate the
  [NixOS-CUDA binary cache](https://cache.nixos-cuda.org/).\
  This binary cache is intended to be used for internal development purposes only.

### CUDA GPU checks

- **jobsets:** `cuda-gpu-checks-[un]stable`
- **definition file:** [./jobsets/cuda-tests.nix](./jobsets/cuda-tests.nix)
- **Content:** All `<package>.*.gpuCheck` instances.\
  `.gpuCheck` package attributes are in-derivation tests that require access to
  an NVIDIA GPU at build time.\
  This requirement is encoded as `requiredSystemFeatures = [ "cuda" ];`.
- **Purpose:** Ensure packages are properly tested on physical hardware.
  Simply building a package with `cudaSupport` does not guarantee correct
  runtime behavior.\
  Therefore, we aim to add as many such _GPU checks_ as possible to important
  hardware-accelerated nixpkgs packages.\
  The role of this jobset is to run all of them in order to prevent spurious
  regressions.


## Roadmap

- [ ] Add channels
    - [x] Create channel jobsets
    - [ ] Publish/push/bump channels
    - [ ] Ask nixpkgs-core team to have protected branches in `NixOS/nixpkgs` for our channels
    - [ ] Make them 'official' channels
