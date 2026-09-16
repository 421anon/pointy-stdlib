{ pointyLib, pointy-lang }:
top:
let
  lib = top.lib;
  sel = top.config.pointy.semantic;
  cfg = top.config.pointy;
in
{
  options.pointy.semantic = {
    language = lib.mkOption {
      type = lib.types.raw;
      default = pointy-lang;
      description = "The pointy language flake (compiler and scanner bundles).";
    };
    pkgs = lib.mkOption {
      type = lib.types.raw;
      description = "The one pkgs for the raw steps and the entry sources.";
    };
    source = lib.mkOption {
      type = lib.types.raw;
      description = "Entry program source (conventionally main.pointy).";
    };
    extensions = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            source = lib.mkOption {
              type = lib.types.nullOr lib.types.raw;
              default = null;
              description = "Extension source document; defaults to the language's same-named extension.";
            };
            path = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = "Source-relative import path; defaults to ext/<name>.pointy.";
            };
          };
        }
      );
      default = {
        csv = { };
      };
      description = "Logical extension name -> { source, path } overrides; csv is pre-enrolled.";
    };
    result = lib.mkOption {
      internal = true;
      type = lib.types.attrs;
      default = { };
      description = "Semantic kernel: the core tables and the raw steps.";
    };
  };

  config.pointy.semantic = (
    let
      # mkFlake fixes the system list.
      system = "x86_64-linux";
      pkgs = sel.pkgs;
      lang = sel.language.lib.forSystem { inherit system pkgs; };
      templates = cfg.templates;

      extensions = builtins.mapAttrs (
        name: spec:
        let
          declared = sel.language.pointyExtensions.${system}.${name} or null;
          source =
            if spec.source != null then
              spec.source
            else if declared != null then
              declared.source
            else
              throw "pointy.semantic: extension `${name}' is not provided by the language; set `extensions.${name}.source'";
        in
        {
          inherit source;
        }
        // lib.optionalAttrs (spec.path != null) {
          inherit (spec) path;
        }
      ) sel.extensions;

      schema = lang.argumentSchema {
        entry = sel.source;
        inherit extensions;
      };
      metas = pointyLib.templateMeta {
        inherit templates;
        schema = schema.document;
      };
      steps = pointyLib.evalSteps (cfg // { inherit pkgs metas; });
    in
    {
      result = {
        inherit metas steps;
      };
    }
  );
}
