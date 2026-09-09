{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    pointy-lang = {
      url = "path:/root/src/pointy-lang";
      inputs.nixpkgs.follows = "nixpkgs";
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
      semanticModule = import ./semantic.nix {
        inherit pointyLib;
        inherit (inputs) pointy-lang;
      };
    in
    {
      lib = pointyLib.api;
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
                  # `nix eval --json '.#pointy.stepConfig'` yields the document.
                  stepConfig = renderStepConfig {
                    schema = builtins.fromJSON (builtins.readFile (toString cfg.semantic.result.contractSchema));
                    adapter = cfg.semantic.result.adapter;
                  };
                  presets = evalPresets cfg;
                  projects = evalProjects cfg;
                  stepDefs = evalStepDefs cfg;
                  srcFiles = cfg.srcFiles;
                  dependencies = evalDependencies (cfg // {
                    contractSchema = cfg.semantic.result.contractSchema;
                  });
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
                          projectOutPaths = evalProjectOutPaths <| cfg // {
                            inherit pkgs;
                            contractSchema = cfg.semantic.result.contractSchema;
                          };
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
