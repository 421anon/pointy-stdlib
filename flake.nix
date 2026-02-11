{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    dream2nix = {
      url = "github:nix-community/dream2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      dream2nix,
      flake-parts,
    }:
    let
      trotterLib = import ./lib.nix inputs trotterLib;
    in
    {
      lib = trotterLib;

      flakeModules.default = top: {
        options.trotter = {
          stepDefs = top.lib.mkOption { type = top.lib.types.attrsOf trotterLib.types.trotter.stepDef; };
          templates = top.lib.mkOption { type = top.lib.types.attrs; };
          projects = top.lib.mkOption { type = top.lib.types.attrsOf trotterLib.types.trotter.project; };
        };

        config = {
          flake.trotter = {
            stepConfig = trotterLib.evalStepConfig { inherit (top.config.trotter) templates; };
            projects = trotterLib.evalProjects { inherit (top.config.trotter) projects stepDefs; };
          };
          perSystem =
            { pkgs, ... }:
            {
              packages = {
                trotter = {
                  type = "derivation";
                  name = "steps";
                }
                // {
                  steps = trotterLib.evalSteps {
                    inherit pkgs;
                    inherit (top.config.trotter) stepDefs templates;
                  };
                };
              };
            };
        };
      };
    };
}
