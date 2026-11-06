# nix-nixpkgs-review's reports of Nixpkgs trees (each evaluated in a derivation, read with import-from-derivation), and
# what changed between two, for the CUDA packages (./cuda-packages.nix) and PR (./nixpkgs-pr.nix) jobsets.
{
  # The trusted tree: its packages build the reports.
  nixpkgs,
  nixNixpkgsReview,
  iets,
  currentSystem,
}:
let
  pkgs = import nixpkgs {
    system = currentSystem;
    config = { };
    overlays = [ ];
  };
  inherit (pkgs) lib;
  nnr = pkgs.callPackage "${nixNixpkgsReview}/lib.nix" { inherit iets; };
in
rec {
  inherit pkgs;

  # The packages of `tree` on `system`, evaluated as Nixpkgs' CI does (./report-args.nix), with the jobs release.nix
  # adds (./release-extra-jobs.nix). A report depends only on its label, tree and settings, so it's built once.
  report =
    label: tree: system: withCUDA:
    nnr.mkReport {
      inherit label tree withCUDA;
      evalSystem = system;
      nixpkgsArgs = ./report-args.nix;
      extraJobs = ./release-extra-jobs.nix;
    };

  # mkJobs' comparison of two reports: diff.json, and changed.json (the paths added, changed or fixed).
  compare = pre: post: nnr.mkJobs { inherit pre post; };
  changed = comparison: lib.importJSON "${comparison}/changed.json";

  # The paths enabling cudaSupport adds, changes or fixes, given a tree's reports without and with it.
  cudaSensitive = noCuda: cuda: changed (compare noCuda cuda);
}
