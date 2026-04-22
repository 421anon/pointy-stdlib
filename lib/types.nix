{ nixpkgs }:
with nixpkgs.lib;
with types;
{
  pointy.step =
    {
      description,
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
        inherit description;
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
        description = "List of " + inner.description.description;
        __toString = _: "TList(" + builtins.toString inner.description + ")";
      };
    };

  pointy.string =
    {
      description,
      display ? { },
    }:
    str
    // {
      description = {
        type.string = { inherit display; };
        inherit description;
        __toString = _: "TString"; # for evaluation error messages
      };
    };

  pointy.stepDef = submodule {
    options = {
      type = mkOption { type = str; };
      name = mkOption { type = str; };
      note = mkOption {
        type = str;
        default = "";
      };
      args = mkOption { type = attrs; };
    };
  };

  pointy.template =
    let
      derivationType = submodule {
        options = {
          derivation = mkOption { type = enum [ { } ]; };
        };
      };

      fileUploadType = submodule {
        options = {
          fileUpload = mkOption {
            type = submodule {
              options = {
                allowedExtensions = mkOption { type = listOf str; };
                description = mkOption { type = str; };
              };
            };
          };
        };
      };

    in
    submodule {
      options = {
        pointy.type = mkOption {
          type = oneOf [
            derivationType
            fileUploadType
          ];
        };

        module = mkOption { type = deferredModule; };
      };
    };

  pointy.project = submodule {
    options = {
      name = mkOption { type = str; };
      hidden = mkOption { type = bool; };
      sortKey = mkOption { type = nullOr int; };
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
