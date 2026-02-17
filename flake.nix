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

        config =
          let
            cfg = top.config.trotter;
            fakeDrv = {
              type = "derivation";
              name = "";
            };
          in
          {
            flake.trotter = {
              stepConfig = trotterLib.evalStepConfig cfg;
              projects = trotterLib.evalProjects cfg;
              inherit (cfg) stepDefs;
            };
            perSystem =
              { pkgs, ... }:
              {
                packages = {
                  trotter = fakeDrv // {
                    steps = trotterLib.evalSteps <| cfg // { inherit pkgs; };
                    projectOutPaths = trotterLib.evalProjectOutPaths <| cfg // { inherit pkgs; };
                  };
                };
              };
          };
      };
    };
}
