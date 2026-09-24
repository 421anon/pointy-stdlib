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
            };
          };

          config =
            let
              cfg = config.pointy;
              stepDefs = pointyLib.evalStepDefs cfg;
              kernel = semantic {
                inherit cfg stepDefs;
                inherit (cfg.semantic) pkgs source;
              };
              inherit (kernel) metas steps certificates;
              dependencies = pointyLib.evalDependencies (cfg // { inherit metas stepDefs; });
              projects = pointyLib.evalProjects {
                inherit (cfg) projects templates presets;
                inherit stepDefs;
              };
              publishedSteps = pointyLib.extendSteps {
                inherit (cfg) templates srcFiles;
                inherit steps stepDefs dependencies certificates;
              };
              outPaths = pointyLib.evalProjectOutPaths { inherit steps projects; };
              projectCertificates = pointyLib.evalProjectCertificates {
                steps = publishedSteps;
                inherit projects;
              };
              publishedProjects = pointyLib.extendProjects {
                inherit projects outPaths;
                certificates = projectCertificates;
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
                  steps = publishedSteps;
                  projects = publishedProjects;
                  autocomplete = evalAutocomplete {
                    inherit (cfg) templates;
                    pkgs = cfg.semantic.pkgs;
                  };
                };

              perSystem =
                { ... }:
                {
                  checks = {
                    pointy-applications = kernel.applicationsCheck;
                  };
                };
            };
        };
    };
}
