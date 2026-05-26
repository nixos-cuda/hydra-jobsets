{
  projectName,
  declInput,
  nixpkgs,
  system ? builtins.currentSystem,
}:
let
  pkgs = import nixpkgs { inherit system; };
in
{
  jobsets =
    (pkgs.writers.writeJSON "jobsets.json" (import ./jobsets.nix).${projectName}).overrideAttrs
      {
        # Pretty-print the output to logs
        buildCommand = ''
          jq -S '.value|fromjson' .attrs.json | tee $out
        '';
      };
}
