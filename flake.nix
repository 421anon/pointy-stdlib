{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
    }:
    let
      pointyLib = import ./lib.nix inputs pointyLib;
      semanticModule = import ./semantic.nix { inherit pointyLib; };
    in
    {
      lib = pointyLib;

      flakeModules = {
        semantic = semanticModule;
        default = top: {
        options.pointy = {
          stepDefs = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.stepDef; };
          templates = top.lib.mkOption { type = top.lib.types.attrs; };
          presets = top.lib.mkOption {
            type = top.lib.types.attrsOf pointyLib.types.pointy.preset;
            default = { };
          };
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
            flake.pointy =
              with pointyLib;
              {
                stepConfig = evalStepConfig cfg;
                presets = evalPresets cfg;
                projects = evalProjects cfg;
                stepDefs = evalStepDefs cfg;
                srcFiles = cfg.srcFiles;
                dependencies = evalDependencies cfg;
                # Semantic kernel, when pointy.semantic.enable: handles +
                # presenter metadata + transport documents + derivation
                # views.  Merged here so flake.pointy keeps a single
                # definer.
              }
              // cfg.semantic.result;
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
                        autocomplete = evalAutocomplete <| cfg // { inherit pkgs; };
                      };
                  };
                };
              };
          };
        };
      };
    };
}
