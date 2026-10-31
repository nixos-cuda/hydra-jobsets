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
    isList
    isString
    elemAt
    ;

  /*
    Map:
    [
      "firefox"
      "opencv"
      "python3Packages.torch"
      "python3Packages.torch.tests.tester-compileCpu.gpuCheck"
      { path = "python3Packages.triton"; platforms = [ "x86_64-linux" ]; }
    ]

    To:
    {
      firefox.x86_64-linux = <drv>;
      firefox.aarch64-linux = <drv>;
      opencv.x86_64-linux = <drv>;
      opencv.aarch64-linux = <drv>;
      python3Packages.torch.x86_64-linux = <drv>;
      python3Packages.torch.aarch64-linux = <drv>;
      python3Packages.torch.tests.tester-compileCpu.gpuCheck.x86_64-linux = <drv>;
      python3Packages.torch.tests.tester-compileCpu.gpuCheck.aarch64-linux = <drv>;
      python3Packages.triton.x86_64-linux = <drv>;
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
            { path = [ "python3Packages" "triton" ]; platforms = [ "x86_64-linux" ]; }
          ];
        }
      */
      (groupBy (x: if isList x then head x else head x.path))

      /*
        {
          firefox = [ [] ];
          python3Packages = [
            [ "torch" ]
            [ "triton" ]
          ];
        }
      */
      (mapAttrs (
        _:
        map (
          x:
          if isList x then
            tail x
          else
            {
              path = tail x.path;
              inherit (x) platforms;
            }
        )
      ))
    ];

  entriesToAttrSet =
    path: entries:
    mapAttrs (
      # python3Packages
      attrName:

      # [ ["torch"] ["torch.tests.gpuCheck"] { path = ["triton"]; platforms = [ "aarch64-linux" ]; } ]
      entries:
      let
        /*
          {
            right = [];
            wrong = [ ["torch"] ["torch.tests.gpuCheck"] { path = ["triton"]; platforms = [ "aarch64-linux" ]; } ];
          }
        */
        byLeaf = partition (entry: if isList entry then entry == [ ] else entry.path == [ ]) entries;

        # ["python3Packages" "torch" ]
        currentPath = path ++ [ attrName ];

        children = entriesToAttrSet currentPath byLeaf.wrong;

        # pkgs.python3Packages.torch
        package = getAttrFromPath currentPath pkgs;
        rightElement = elemAt byLeaf.right 0;
        platforms = if rightElement == [ ] then getPlatforms package else rightElement.platforms;

        /*
          {
            x86_64-linux = <pkgs-x86_64-linux>.python3Packages.torch;
            aarch64-linux = <pkgs-aarch64-linux>.python3Packages.torch;
          };
        */
        packageJobs = forMatchingSystems platforms (
          system:
          let
            # <pkgs-system>.python3Packages.torch;
            pkg = (getAttrFromPath currentPath (pkgsFor system));
          in
          {
            cuda = hydraJob' pkg;
          }
        );
      in
      children // (optionalAttrs ((builtins.length byLeaf.right) > 0) packageJobs)

    ) (groupEntries entries);

  jobs = (
    pipe channelBlockers [
      # [ [ "python3Packages" "torch" ] [ "firefox" ] ]
      (map (
        entry:
        if isString entry then splitString "." entry else entry // { path = splitString "." entry.path; }
      ))

      (entriesToAttrSet [ ])
    ]
  );
in
jobs
