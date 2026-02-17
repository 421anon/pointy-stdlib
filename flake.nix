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
            flake.trotter = with trotterLib; {
              stepConfig = evalStepConfig cfg;
              projects = evalProjects cfg;
              stepDefs = evalStepDefs cfg;
            };
            perSystem =
              { pkgs, ... }:
              {
                packages = {
                  trotter = with trotterLib; fakeDrv // {
                    steps = evalSteps <| cfg // { inherit pkgs; };
                    projectOutPaths = evalProjectOutPaths <| cfg // { inherit pkgs; };
                  };
                };
              };
          };
      };
    };
}
