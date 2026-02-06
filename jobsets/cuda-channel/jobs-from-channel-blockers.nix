{
  lib,
  release-lib,
  channelBlockers,
  channelName,
}:

let
  inherit (release-lib)
    forMatchingSystems
    getPlatforms
    hydraJob'
    pkgs
    pkgsFor
    ;
  inherit (lib)
    getAttrFromPath
    groupBy
    head
    mapAttrs
    optionalAttrs
    partition
    pipe
    splitString
    tail
    ;

  /*
    Map:
    [
      "firefox"
      "opencv"
      "python3Packages.torch"
      "python3Packages.torch.tests.tester-compileCpu.gpuCheck"
    ]

    To:
    {
      firefox.x86_64-linux = <drv>;
      opencv.x86_64-linux = <drv>;
      python3Packages.torch.x86_64-linux = <drv>;
      python3Packages.torch.tests.tester-compileCpu.gpuCheck.x86_64-linux = <drv>;
    }
  */

  groupEntries =
    entries:
    pipe entries [
      /*
        {
          firefox = [ [ "firefox" ] ];
          python3Packages = [
            [ "python3Packages" "torch" ]
            [ "python3Packages" "triton" ]
          ];
        }
      */
      (groupBy head)

      /*
        {
          firefox = [ [] ];
          python3Packages = [
            [ "torch" ]
            [ "triton" ]
          ];
        }
      */
      (mapAttrs (_: map tail))
    ];

  entriesToAttrSet =
    path: entries:
    mapAttrs (
      # python3Packages
      attrName:

      # [ ["torch"] ["torch.tests.gpuCheck"] ["triton"] ]
      entries:
      let
        /*
          {
            right = [];
            wrong = [ ["torch"] ["torch.tests.gpuCheck"] ["triton"] ];
          }
        */
        byLeaf = partition (entry: entry == [ ]) entries;

        # ["python3Packages" "torch" ]
        currentPath = path ++ [ attrName ];

        children = entriesToAttrSet currentPath byLeaf.wrong;

        # pkgs.python3Packages.torch
        package = getAttrFromPath currentPath pkgs;

        /*
          {
            x86_64-linux = <pkgs-x86_64-linux>.python3Packages.torch;
            aarch64-linux = <pkgs-aarch64-linux>.python3Packages.torch;
          };
        */
        packageJobs = forMatchingSystems (getPlatforms package) (
          system:
          let
            # <pkgs-system>.python3Packages.torch;
            pkg = (getAttrFromPath currentPath (pkgsFor system));
          in
          hydraJob' pkg
        );
      in
      children // (optionalAttrs ((builtins.length byLeaf.right) > 0) packageJobs)

    ) (groupEntries entries);

  jobs = (
    pipe channelBlockers [
      # [ [ "python3Packages" "torch" ] [ "firefox" ] ]
      (map (pathStr: splitString "." pathStr))

      (entriesToAttrSet [ ])
    ]
  );
in
jobs
