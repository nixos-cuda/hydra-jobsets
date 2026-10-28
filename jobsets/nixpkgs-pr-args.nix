# The arguments the PR jobset (./nixpkgs-pr.nix) imports Nixpkgs with: for its jobs, through release-lib, and for
# nix-nixpkgs-review's reports, whose evaluation imports this file as mkReport.nix's `nixpkgsArgs` (which is passed
# `withCA` as well).
{ withCUDA, ... }:
let
  # Known vulnerabilities to allow for CI:
  # - tensorrt:
  #   - [CVE-2026-24188](https://github.com/NixOS/nixpkgs/issues/522570): OOB write
  # - vllm:
  #   - https://github.com/vllm-project/vllm/security/advisories/GHSA-7972-pg2x-xr59 (CVE-2026-27893)
  #   - https://github.com/vllm-project/vllm/security/advisories/GHSA-83vm-p52w-f9pw (CVE-2026-44223)
  #   - https://github.com/vllm-project/vllm/security/advisories/GHSA-hpv8-x276-m59f (CVE-2026-44222)
  permittedVulnerabilities = [
    "CVE-2026-24188: OOB write"
    "CVE-2026-27893"
    "CVE-2026-44223"
    "CVE-2026-44222"
  ];
in
{
  config = {
    # TODO: why not simply "allowUnfree = true"?
    # allowUnfreePredicate =
    #   let
    #     cudaLib = (import "${nixpkgs}/pkgs/development/cuda-modules/_cuda").lib;
    #   in
    #   cudaLib.allowUnfreeCudaPredicate;
    allowUnfree = true;
    cudaSupport = withCUDA;
    inHydra = true;

    # Don't evaluate duplicate and/or deprecated attributes
    allowAliases = false;

    # Allow insecure packages whose known vulnerabilities are all permitted above
    allowInsecurePredicate =
      pkg:
      builtins.all (vulnerability: builtins.elem vulnerability permittedVulnerabilities) (
        pkg.meta.knownVulnerabilities or [ ]
      );
  };

  __allowFileset = false;
}
