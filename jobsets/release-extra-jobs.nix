# Jobs Nixpkgs' release.nix and ci/eval/outpaths.nix add to the package set's (which nix-nixpkgs-review's reports walk),
# for the reports' `extraJobs` (so this file is copied to the store on its own): a function of the package set,
# returning the jobs at their attribute paths in it.
#
# Not release.nix's `pkgsRocm` (AMD GPUs, which this Hydra doesn't have) or the stdenvs of `pkgsLLVM`, `pkgsMusl` and
# the other variants, which have nothing to do with CUDA: each would be another Nixpkgs for every report to evaluate.
pkgs:
let
  recurse = attrs: attrs // { recurseForDerivations = true; };
in
recurse {
  # HLS for each GHC release.nix builds it with.
  haskell = recurse {
    packages = recurse (
      pkgs.lib.genAttrs [ "ghc96" "ghc98" "ghc910" "ghc912" ] (
        ghc: recurse { inherit (pkgs.haskell.packages.${ghc}) haskell-language-server; }
      )
    );
  };

  nixosTests = recurse { inherit (pkgs.nixosTests) simple-container simple-vm; };
}
