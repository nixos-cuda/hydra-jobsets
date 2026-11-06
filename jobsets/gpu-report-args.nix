# The arguments the GPU checks jobset's (./cuda-tests.nix) nix-nixpkgs-review report imports Nixpkgs with (as its
# `nixpkgsArgs`, so this file is copied to the store on its own). Every GPU check is found, including those of broken,
# insecure and unsupported packages; the jobs are evaluated with ./nixpkgs-args.nix, so Hydra shows why those fail.
{ withCUDA, ... }:
{
  config = {
    allowAliases = false;
    allowBroken = true;
    allowInsecurePredicate = _: true;
    allowUnfree = true;
    allowUnsupportedSystem = true;
    cudaSupport = withCUDA;
    inHydra = true;
  };

  __allowFileset = false;
}
