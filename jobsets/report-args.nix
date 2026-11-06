# The arguments nix-nixpkgs-review's reports import Nixpkgs with (as their `nixpkgsArgs`, so this file is copied to the
# store on its own) in the PR (./nixpkgs-pr.nix) and CUDA packages (./cuda-packages.nix) jobsets. As in Nixpkgs' CI
# (ci/eval/outpaths.nix), unfree and insecure packages are evaluated, so that a change to one is a job. The jobs are
# evaluated with the jobset's own arguments (./nixpkgs-args.nix, ./nixpkgs-pr-args.nix): a job those refuse is an
# evaluation error in Hydra, rather than left out.
{ withCUDA, ... }:
{
  config = {
    allowAliases = false;
    allowInsecurePredicate = _: true;
    allowUnfree = true;
    checkMeta = true;
    cudaSupport = withCUDA;
    inHydra = true;
  };

  __allowFileset = false;
}
