{
  inputs = {
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

      flakeModules.default =
        {
          self,
          config,
          lib,
          ...
        }:
        {
          options.pointy = {
            stepDefs = lib.mkOption { type = lib.types.attrsOf pointyLib.types.pointy.stepDef; };
            templates = lib.mkOption { type = lib.types.attrs; };
            presets = lib.mkOption {
              type = lib.types.attrsOf pointyLib.types.pointy.preset;
              default = { };
            };
            projects = lib.mkOption { type = lib.types.attrsOf pointyLib.types.pointy.project; };
            srcFiles = lib.mkOption { type = lib.types.raw; };
            semantic = {
              pkgs = lib.mkOption {
                type = lib.types.raw;
                description = "The one pkgs for the raw steps and the entry sources.";
              };
              source = lib.mkOption {
                type = lib.types.raw;
                description = "Entry program source (conventionally main.pointy).";
              };
              schema = lib.mkOption {
                type = lib.types.path;
                description = "Committed argument-schema document (conventionally pointy.schema.json); must live inside this flake so `pointy-schema` can regenerate it.";
              };
            };
          };

          config =
            let
              cfg = config.pointy;
              schemaPath = toString cfg.semantic.schema;
              schemaPrefix = "${self.outPath}/";
              stepDefs = pointyLib.evalStepDefs cfg;
              kernel = semantic {
                inherit cfg stepDefs;
                inherit (cfg.semantic) pkgs source schema;
                schemaRel =
                  assert
                    lib.hasPrefix schemaPrefix schemaPath
                    || throw "pointy.semantic.schema must live inside the host flake, so `pointy-schema` can regenerate it";
                  lib.removePrefix schemaPrefix schemaPath;
              };
              inherit (kernel) metas steps certificates;
              projects = pointyLib.evalProjects {
                inherit (cfg) projects templates presets;
                inherit stepDefs;
              };
            in
            {
              flake.pointy =
                with pointyLib;
                {
                  stepConfig = renderStepConfig {
                    inherit (cfg) templates;
                    inherit metas;
                  };
                  presets = evalPresets {
                    inherit (cfg) templates presets;
                  };
                  inherit projects stepDefs steps certificates;
                  srcFiles = cfg.srcFiles;
                  dependencies = evalDependencies (cfg // { inherit metas stepDefs; });
                  projectOutPaths = evalProjectOutPaths { inherit steps projects; };
                  projectCertificates = evalProjectCertificates { inherit certificates projects; };
                  autocomplete = evalAutocomplete {
                    inherit (cfg) templates;
                    pkgs = cfg.semantic.pkgs;
                  };
                };

              perSystem =
                { ... }:
                {
                  checks = {
                    pointy-schema = kernel.schemaDrift;
                    pointy-applications = kernel.applicationsCheck;
                  };
                  apps.pointy-schema = {
                    type = "app";
                    program = "${kernel.schemaWriter}/bin/pointy-schema";
                  };
                };
            };
        };
    };
}
