{
  system,
  runCommand,
  nixpkgs,
  evalSystems ? [ "x86_64-linux" ],
}:
let
  ci = import "${nixpkgs}/ci" { inherit system nixpkgs; };

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
runCommand "extract-json" { } ''
  cp ${withCuda}/changed-paths.json $out
''
