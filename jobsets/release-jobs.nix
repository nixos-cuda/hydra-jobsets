# Hydra jobs for attribute paths of Nixpkgs, as Nixpkgs' release.nix makes them (and so as ci/eval listed them): through
# release-lib, on each system the path is given for that the package's platforms (`meta.hydraPlatforms`, else
# `meta.platforms`) allow, and none for a function.
#
# A report from nix-nixpkgs-review has what a function returns when called with its defaults (e.g. `wrapOBS`), as
# nix-eval-jobs does, and every job, whatever its `meta.hydraPlatforms`: so both are left out here, not there.
{
  lib,
  releaseLib,
}:
let
  inherit (releaseLib)
    forMatchingSystems
    getPlatforms
    hydraJob'
    pkgsFor
    supportedMatches
    ;

  # [ { system; path; } ] as a tree of attribute paths, each to its systems, e.g.
  # { cool = [ "x86_64-linux" "aarch64-linux" ]; python3Packages.torch = [ "x86_64-linux" ]; }
  toTree =
    entries:
    lib.mapAttrs
      (
        _: entries:
        let
          byLeaf = lib.partition (entry: entry.path == [ ]) entries;
        in
        if byLeaf.wrong == [ ] then
          lib.catAttrs "system" entries
        else if byLeaf.right == [ ] then
          toTree entries
        else
          throw "Conflicting attr paths:${
            lib.concatMapStrings (entry: "\n- ${lib.concatStringsSep "." entry.path}") entries
          }"
      )
      (
        lib.groupBy' (rest: entry: rest ++ [ (entry // { path = lib.tail entry.path; }) ]) [ ] (
          entry: lib.head entry.path
        ) entries
      );
in
# The jobs for `entries`, each job as `wrap` makes it (e.g. `job: { cuda = job; }`), e.g.
# { cool.x86_64-linux = wrap <job>; cool.aarch64-linux = wrap <job>; python3Packages.torch.x86_64-linux = wrap <job>; }
wrap: entries:
lib.mapAttrsRecursive (
  path: systems:
  lib.filterAttrs (_: job: job != null) (
    forMatchingSystems systems (
      system:
      let
        value = lib.getAttrFromPath path (pkgsFor system);
      in
      if lib.isFunction value || !lib.elem system (supportedMatches (getPlatforms value)) then
        null
      else
        wrap (hydraJob' value)
    )
  )
) (toTree entries)
