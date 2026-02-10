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
    rec {
      lib = import ./lib.nix inputs;

      flakeModules.default = top: {
        options.trotter = {
          stepDefs = top.lib.mkOption { type = top.lib.types.attrs; };
          templates = top.lib.mkOption { type = top.lib.types.attrs; };
          projects = top.lib.mkOption { type = top.lib.types.attrs; };
        };

        config = {
          flake.trotter = {
            stepConfig = lib.evalStepConfig { inherit (top.config.trotter) templates; };
            projects = lib.evalProjects { inherit (top.config.trotter) projects stepDefs; };
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
                  steps = lib.evalSteps {
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
