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
    in
    {
      lib = pointyLib;

      flakeModules.default = top: {
        options.pointy = {
          stepDefs = top.lib.mkOption {
            type = top.lib.types.attrsOf pointyLib.types.pointy.stepDef;
            default = { };
          };
          templates = top.lib.mkOption {
            type = top.lib.types.attrs;
            default = { };
          };
          presets = top.lib.mkOption {
            type = top.lib.types.attrsOf pointyLib.types.pointy.preset;
            default = { };
          };
          projects = top.lib.mkOption {
            type = top.lib.types.attrsOf pointyLib.types.pointy.project;
            default = { };
          };
          srcFiles = top.lib.mkOption {
            type = top.lib.types.raw;
            default = { };
          };
          deps = top.lib.mkOption {
            type = top.lib.types.attrsOf (
              top.lib.types.submodule {
                options.input = top.lib.mkOption {
                  type = top.lib.types.str;
                  description = "The flake-input key in this repo's flake.nix that pins the dependency.";
                };
                options.repo = top.lib.mkOption {
                  type = top.lib.types.nullOr top.lib.types.str;
                  default = null;
                  description = "The pointy registry name of the dependency. Optional; when absent Pointy resolves the input's locked URL against the registry.";
                };
              }
            );
            default = { };
            description = ''
              Pointy repositories this repo depends on, keyed by namespace.
              Each entry maps a namespace to `{ input, repo ? null }` where
              `input` is the flake input key and `repo` the registry name.
            '';
          };
        };

        config =
          let
            cfg = top.config.pointy;
            fakeDrv = {
              type = "derivation";
              name = "";
            };

            # Resolve a declared dependency to its flake output. Throws a
            # helpful error when the input is unknown or not a pointy flake.
            depOutput =
              ns: decl:
              let
                inputName = decl.input;
              in
              # `self` is always injected into inputs by mkFlake's
              # withDefaultNixpkgs; depending on it would recurse into this very
              # flake's pointy output (stack overflow).
              if inputName == "self" then
                throw "pointy.deps: namespace `${ns}` may not depend on `self` (a repo cannot depend on its own pointy output)."
              else if !(builtins.hasAttr inputName top.inputs) then
                throw "pointy.deps: namespace `${ns}` refers to input `${inputName}` which is not declared in the flake's `inputs`."
              else if !(top.inputs.${inputName} ? pointy) then
                throw "pointy.deps: input `${inputName}` (namespace `${ns}`) is not a pointy flake: it has no `pointy` output."
              else
                top.inputs.${inputName};

            # Backend contract (`#pointy.deps`): namespace -> { input, repo? }.
            # Pure metadata of this repo's own committed state; does not force
            # evaluation of dependency content.
            depsJson = builtins.mapAttrs (
              _: decl:
              { input = decl.input; }
              // (if decl.repo != null then { inherit (decl) repo; } else { })
            ) cfg.deps;

            # Mount each co-managed dependency's pointy output under a
            # namespace so this repo can refer to its stepDefs/templates / projects / presets / srcFiles.
            domainNamespaces = builtins.mapAttrs (ns: decl: (depOutput ns decl).pointy) cfg.deps;

            # Per-system mount: also exposes dependency built steps / projectOutPaths / autocomplete.
            # Strips the dependency's own fakeDrv package markers (type/name) from the
            # namespace root so `#pointy.namespaces.<ns>` is a clean pointy surface.
            perSystemNamespaces =
              pkgs:
              builtins.mapAttrs (
                ns: decl:
                let
                  dep = depOutput ns decl;
                in
                (dep.pointy or { })
                // (builtins.removeAttrs (dep.packages.${pkgs.system}.pointy or { }) [
                  "type"
                  "name"
                ])
              ) cfg.deps;
          in
          {
            flake.pointy = with pointyLib; {
              stepConfig = evalStepConfig cfg;
              presets = evalPresets cfg;
              projects = evalProjects cfg;
              stepDefs = evalStepDefs cfg;
              srcFiles = cfg.srcFiles;
              dependencies = evalDependencies cfg;
              deps = depsJson;
              namespaces = domainNamespaces;
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
                        autocomplete = evalAutocomplete <| cfg // { inherit pkgs; };
                        namespaces = perSystemNamespaces pkgs;
                      };
                  };
                };
              };
          };
      };
    };
}
