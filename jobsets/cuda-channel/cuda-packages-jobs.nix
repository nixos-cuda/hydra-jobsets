{
  lib,
  release-lib,
}:
let
  inherit (lib) isDerivation;
  inherit (release-lib) getPlatforms pkgs;

  collectCudaPackage = _: pkg: lib.optionals (isDerivation pkg) (getPlatforms pkg);

  /*
    {
      cudaPackages.cuda_nvcc = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
    }
  */
  cudaPackages = lib.mapAttrs collectCudaPackage pkgs.cudaPackages;

  /*
    {
      cudaPackages.cuda_nvcc.x86_64-linux = <derivation>;
    }
  */
  jobs = release-lib.mapTestOn { inherit cudaPackages; };
in
jobs
