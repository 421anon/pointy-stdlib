{ nixpkgs }:
with nixpkgs.lib;
with types;
let
  requirementsType = submodule {
    options = {
      ram = mkOption { type = str; };
      cpu = mkOption { type = int; };
      ior = mkOption { type = str; };
      iow = mkOption { type = str; };
    };
  };
in
{
  pointy.step =
    {
      description,
      displayName ? null,
      allowedTypes ? null,
    }:
    (addCheck package (
      pkg:
      hasAttrByPath [ "meta" "pointy" "type" ] pkg
      && (allowedTypes == null || elem pkg.meta.pointy.type allowedTypes)
    ))
    // {
      description = {
        type.step = optionalAttrs (allowedTypes != null) { inherit allowedTypes; };
        inherit description displayName;
        __toString =
          _: "TStep" + optionalString (allowedTypes != null) "[${builtins.toString allowedTypes}]";
      };
    };

  pointy.listOf =
    inner:
    listOf inner
    // {
      description = {
        type.list = inner.description.type;
        description = "List of " + toLower inner.description.description;
        displayName = inner.description.displayName or null;
        __toString = _: "TList(" + builtins.toString inner.description + ")";
      };
    };

  pointy.string =
    {
      description,
      displayName ? null,
      display ? { },
      autocomplete ? null,
    }:
    str
    // {
      description = {
        type.string = { inherit display autocomplete; };
        inherit description displayName;
        __toString = _: "TString"; # for evaluation error messages
      };
    };

  pointy.enum =
    {
      values,
      description,
      displayName ? null,
      valueDisplayNames ? { },
    }:
    str
    // {
      description = {
        type.enum = values;
        type.enumDisplayNames = valueDisplayNames;
        inherit description displayName;
        __toString = _: "TEnum[" + builtins.toString values + "]";
      };
    };

  pointy.record =
    arg:
    let
      hasMetadata = arg ? fields;
      fields = if hasMetadata then arg.fields else arg;
      displayName = if hasMetadata then arg.displayName or null else null;
    in
    (submodule {
      options = mapAttrs (_: fieldType: mkOption { type = fieldType; }) fields;
    })
    // {
      getSubModules = null;
      description = {
        type.record = {
          fields = mapAttrs (_: fieldType: {
            inherit (fieldType.description) description;
            type = fieldType.description.type;
            displayName = fieldType.description.displayName or null;
          }) fields;
        };
        description = "Record with fields: " + concatStringsSep ", " (attrNames fields);
        inherit displayName;
        __toString = _: "TRecord";
      };
    };

  pointy.requirements = requirementsType;

  pointy.stepDef = submodule {
    options = {
      type = mkOption { type = str; };
      name = mkOption { type = str; };
      note = mkOption {
        type = str;
        default = "";
      };
      args = mkOption { type = attrs; };
      requirements = mkOption {
        type = nullOr requirementsType;
        default = null;
      };
    };
  };

  pointy.template =
    let
      derivationType = submodule {
        options = {
          derivation = mkOption {
            type = submodule {
              options = {
                withSrcFiles = mkOption {
                  type = bool;
                  default = false;
                };
              };
            };
            default = { };
          };
        };
      };

      fileUploadType = submodule {
        options = {
          fileUpload = mkOption {
            type = submodule {
              options = {
                allowedExtensions = mkOption { type = listOf str; };
              };
            };
          };
        };
      };

      downloadType = submodule {
        options = {
          download = mkOption {
            type = submodule { };
          };
        };
      };

    in
    submodule {
      options = {
        sortKey = mkOption {
          type = nullOr int;
          default = null;
        };
        displayName = mkOption {
          type = nullOr str;
          default = null;
        };
        description = mkOption {
          type = nullOr str;
          default = null;
        };
        pointy.type = mkOption {
          type = oneOf [
            derivationType
            fileUploadType
            downloadType
          ];
        };

        requirements = mkOption {
          type = functionTo requirementsType;
          default = _: {
            ram = "1G";
            cpu = 1;
            ior = "0";
            iow = "0";
          };
        };

        module = mkOption { type = deferredModule; };

        constructor = mkOption { type = deferredModule; };
      };
    };

  pointy.preset = submodule {
    options = {
      displayName = mkOption { type = str; };
      description = mkOption {
        type = nullOr str;
        default = null;
      };
      sortKey = mkOption {
        type = nullOr int;
        default = null;
      };
      templates = mkOption { type = listOf str; };
    };
  };

  pointy.project = submodule {
    options = {
      name = mkOption { type = str; };
      hidden = mkOption { type = bool; };
      sortKey = mkOption { type = nullOr int; };
      preset = mkOption {
        type = nullOr str;
        default = null;
      };
      templates = mkOption {
        type = nullOr (listOf str);
        default = null;
      };
      steps = mkOption {
        type =
          listOf
          <| submodule {
            options = {
              id = mkOption { type = int; };
              hidden = mkOption { type = bool; };
              sortKey = mkOption { type = nullOr int; };
            };
          };
      };
    };
  };
}
