# Hydra jobs for attribute paths of Nixpkgs, as Nixpkgs' release.nix makes them (and so as ci/eval listed them): through
# release-lib, on each system the path is given for that the package's platforms (`meta.hydraPlatforms`, else
# `meta.platforms`) allow. There is none for:
# - a function: a report from nix-nixpkgs-review has what a function returns when called with its defaults (e.g.
#   `wrapOBS`), as nix-eval-jobs does;
# - a package with a problem of a kind Nixpkgs doesn't use internally (`removal`, `deprecated`), which ci/eval leaves
#   out (ci/eval/pre-eval.nix).
{
  lib,
  releaseLib,
}:
let
  inherit (releaseLib)
    forMatchingSystems
    getPlatforms
    hydraJob'
    pkgs
    pkgsFor
    supportedMatches
    ;

  inherit (import "${pkgs.path}/pkgs/stdenv/generic/problems.nix" { inherit lib; })
    disallowNixpkgsInternalUseKinds
    ;

  isJob =
    system: value:
    !lib.isFunction value
    && !lib.any (problem: disallowNixpkgsInternalUseKinds ? ${problem.kind}) (
      lib.attrValues (value.meta.problems or { })
    )
    && lib.elem system (supportedMatches (getPlatforms value));

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
        # Not lib.groupBy', whose lazy fold overflows the stack for a large package set (e.g. python313Packages).
        lib.mapAttrs (_: map (entry: entry // { path = lib.tail entry.path; })) (
          builtins.groupBy (entry: lib.head entry.path) entries
        )
      );
in
# The jobs for the attribute paths `changedOn` gives for each of `systems`, each job as `wrap` makes it (e.g.
# `job: { cuda = job; }`), e.g.
# { cool.x86_64-linux = wrap <job>; cool.aarch64-linux = wrap <job>; python3Packages.torch.x86_64-linux = wrap <job>; }
wrap: systems: changedOn:
lib.mapAttrsRecursive (
  path: systems:
  let
    valueOn = system: lib.getAttrFromPath path (pkgsFor system);
  in
  # Systems are chosen before the jobs are made, so that a job that fails to evaluate is an error of its own.
  forMatchingSystems (lib.filter (system: isJob system (valueOn system)) systems) (
    system: wrap (hydraJob' (valueOn system))
  )
) (toTree (lib.concatMap (system: map (path: { inherit system path; }) (changedOn system)) systems))
