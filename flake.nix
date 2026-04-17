{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    dream2nix = {
      url = "github:nix-community/dream2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      dream2nix,
      flake-parts,
    }:
    let
      pointyLib = import ./lib.nix inputs pointyLib;
    in
    {
      lib = pointyLib;

      flakeModules.default = top: {
        options.pointy = {
          stepDefs = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.stepDef; };
          templates = top.lib.mkOption { type = top.lib.types.attrs; };
          projects = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.project; };
          srcFiles = top.lib.mkOption { type = top.lib.types.raw; };
        };

        config =
          let
            cfg = top.config.pointy;
            fakeDrv = {
              type = "derivation";
              name = "";
            };
          in
          {
            flake.pointy = with pointyLib; {
              stepConfig = evalStepConfig cfg;
              projects = evalProjects cfg;
              stepDefs = evalStepDefs cfg;
              srcFiles = cfg.srcFiles;
              dependencies = evalDependencies cfg;
            };
            perSystem =
              { pkgs, ... }:
              {
                config = {
                  packages = {
                    pointy =
                      with pointyLib;
                      fakeDrv
                      // {
                        steps = evalSteps <| cfg // { inherit pkgs; };
                        projectOutPaths = evalProjectOutPaths <| cfg // { inherit pkgs; };
                      };
                  };
                };
              };
          };
      };
    };
}
