{
  inputs = {
    # The compiler comes from `pointy-lang`, so this library builds it with
    # the rev that language is locked to; hosts override with
    # `pointy-stdlib.inputs.nixpkgs.follows = "nixpkgs"`.
    nixpkgs.follows = "pointy-lang/nixpkgs";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    pointy-lang = {
      url = "path:/root/src/pointy-lang";
    };
  };

  outputs =
    inputs@{ ... }:
    let
      pointyLib = import ./lib.nix inputs;
      semantic = import ./semantic.nix {
        inherit pointyLib;
        inherit (inputs) pointy-lang;
      };
    in
    {
      lib = pointyLib.api;

      flakeModules.default = top: {
        options.pointy = {
          stepDefs = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.stepDef; };
          templates = top.lib.mkOption { type = top.lib.types.attrs; };
          presets = top.lib.mkOption {
            type = top.lib.types.attrsOf pointyLib.types.pointy.preset;
            default = { };
          };
          projects = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.project; };
          srcFiles = top.lib.mkOption { type = top.lib.types.raw; };
          semantic = {
            pkgs = top.lib.mkOption {
              type = top.lib.types.raw;
              description = "The one pkgs for the raw steps and the entry sources.";
            };
            source = top.lib.mkOption {
              type = top.lib.types.raw;
              description = "Entry program source (conventionally main.pointy).";
            };
          };
        };

        config =
          let
            cfg = top.config.pointy;
            kernel = semantic {
              inherit cfg;
              inherit (cfg.semantic) pkgs source;
            };
            inherit (kernel) metas steps;
            projects = pointyLib.evalProjects cfg;
          in
          {
            flake.pointy =
              with pointyLib;
              {
                stepConfig = renderStepConfig {
                  inherit (cfg) templates;
                  inherit metas;
                };
                presets = evalPresets cfg;
                inherit projects;
                stepDefs = evalStepDefs cfg;
                srcFiles = cfg.srcFiles;
                dependencies = evalDependencies (cfg // { inherit metas; });
                inherit steps;
                projectOutPaths = evalProjectOutPaths { inherit steps projects; };
                autocomplete = evalAutocomplete <| cfg // { inherit pkgs; };
              };
          };
      };
    };
}
