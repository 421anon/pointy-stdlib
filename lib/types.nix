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
