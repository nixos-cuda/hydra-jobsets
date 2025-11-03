{
  pkgs,
  nixpkgs,
  evalSystems, # ? [ "x86_64-linux" ],
}:
let
  ci = import "${nixpkgs}/ci" {
    inherit nixpkgs;
    inherit (pkgs.stdenv.hostPlatform) system;
  };

  withoutCuda =
    (ci.eval {
      extraNixpkgsConfig = {
        allowUnfree = true;
        cudaSupport = false;
      };
    }).baseline
      {
        inherit evalSystems;
      };

  withCuda =
    (ci.eval {
      extraNixpkgsConfig = {
        allowUnfree = true;
        cudaSupport = true;
      };
    }).full
      {
        baseline = withoutCuda;
        inherit evalSystems;
      };
in
pkgs.runCommand "extract-json" { } ''
  cp ${withCuda}/changed-paths.json $out
''
