{ nixpkgs }:
with nixpkgs.lib;
with types;
{
  trotter.step =
    allowedTypes: description:
    (addCheck package (pkg: lists.any (t: pkg.meta.trotter.type == t) allowedTypes))
    // {
      description = {
        type.step = { inherit allowedTypes; };
        inherit description;
        __toString = _: "TStep [" + builtins.toString allowedTypes + "]";
      };
    };

  trotter.string =
    description:
    str
    // {
      description = {
        type.string = { };
        inherit description;
        __toString = _: "TString";
      };
    };

  trotter.stepDef = submodule {
    options = {
      type = mkOption { type = str; };
      name = mkOption { type = str; };
      args = mkOption { type = attrs; };
    };
  };

  trotter.template =
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
        trotter.type = mkOption {
          type = oneOf [
            derivationType
            fileUploadType
          ];
        };

        module = mkOption { type = deferredModule; };
      };
    };

  trotter.project = submodule {
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
