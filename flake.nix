{
  inputs = {
    nixpkgs = {
      url = "github:NixOS/nixpkgs";
    };
    # flake-parts' lib comes from this flake's nixpkgs (upstream's
    # recommended wiring), so a host that follows this flake's nixpkgs
    # gets one nixpkgs for the whole graph.
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    # The compiler builds with this flake's nixpkgs; the host decides
    # that nixpkgs by following this flake's own nixpkgs.
    pointy-lang = {
      url = "path:/root/src/pointy-lang";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      nixpkgs,
      flake-parts,
      pointy-lang,
    }:
    let
      pointyLib = import ./lib.nix inputs pointyLib;
      semanticModule = import ./semantic.nix {
        inherit pointyLib;
        inherit (inputs) pointy-lang;
      };
    in
    {
      lib = pointyLib;
      # The pointy language flake hosts take as `semantic.language`.
      language = pointy-lang;

      flakeModules = {
        semantic = semanticModule;
        default = top: {
        options.pointy = {
          stepDefs = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.stepDef; };
          templates = top.lib.mkOption { type = top.lib.types.attrs; };
          presets = top.lib.mkOption {
            type = top.lib.types.attrsOf pointyLib.types.pointy.preset;
            default = { };
          };
          projects = top.lib.mkOption { type = top.lib.types.attrsOf pointyLib.types.pointy.project; };
          srcFiles = top.lib.mkOption { type = top.lib.types.raw; };
        };

        config =
          let
            cfg = top.config.pointy;
            fakeDrv = {
              type = "derivation";
              name = "";
            };
          in
          {
            flake.pointy =
              let
                stepConfigDoc = with pointyLib;
                  builtins.fromJSON (builtins.readFile (mkStepConfig {
                    pkgs = cfg.semantic.pkgs;
                    schema = cfg.semantic.result.contractSchema;
                    inherit (cfg) templates;
                  }));
              in
              with pointyLib;
              {
                # stepConfig is the host-generated merge document: the
                # core argument schema with the host's presentation
                # overrides.  The merge derivation is realized at
                # evaluation (user-authorized IFD) and its document read
                # here, so `nix eval --json '.#pointy.stepConfig'`
                # yields the document directly.
                stepConfig = stepConfigDoc;
                presets = evalPresets cfg;
                projects = evalProjects cfg;
                stepDefs = evalStepDefs cfg;
                srcFiles = cfg.srcFiles;
                dependencies = evalDependencies (cfg // {
                  contractSchema = cfg.semantic.result.contractSchema;
                });
                # The semantic kernel: presenter metadata + transport
                # documents + derivation views.  Merged here so
                # flake.pointy keeps a single definer.
              }
              // cfg.semantic.result;
            perSystem =
              { pkgs, ... }:
              {
                config = {
                  packages = {
                    pointy =
                      with pointyLib;
                      fakeDrv
                      // {
                        steps = evalSteps <| cfg // {
                          inherit pkgs;
                          contractSchema = cfg.semantic.result.contractSchema;
                        };
                        projectOutPaths = evalProjectOutPaths <| cfg // {
                          inherit pkgs;
                          contractSchema = cfg.semantic.result.contractSchema;
                        };
                        autocomplete = evalAutocomplete <| cfg // { inherit pkgs; };
                      };
                  };
                };
              };
          };
        };
      };
    };
}
