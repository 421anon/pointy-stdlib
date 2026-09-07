{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
    };
    pointy-lang = {
      url = "path:/root/src/pointy-lang";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      pointy-lang,
    }:
    let
      pointyLib = import ./lib.nix inputs pointyLib;
      semanticModule = import ./semantic.nix { inherit pointyLib; };
    in
    {
      lib = pointyLib;
      # The pointy language flake hosts take as `semantic.language`.
      language = pointy-lang;

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
                # stepConfig is host-generated from the CORE schema: the
                # flake output is the realized merge derivation (built
                # from the host contractSchema over the enrolled
                # sources).  Semantic is always on.
                stepConfig = mkStepConfig {
                  pkgs = cfg.semantic.pkgs;
                  schema = cfg.semantic.result.contractSchema;
                  inherit (cfg) templates;
                };
                presets = evalPresets cfg;
                projects = evalProjects cfg;
                stepDefs = evalStepDefs cfg;
                srcFiles = cfg.srcFiles;
                dependencies = evalDependencies cfg;
                # The semantic kernel: handles + presenter metadata +
                # transport documents + derivation views.  Merged here so
                # flake.pointy keeps a single definer.
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
                        steps = evalSteps <| cfg // {
                          inherit pkgs;
                          contractSchema = cfg.semantic.result.contractSchema;
                        };
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
