{ self, nixpkgs, flake-parts, pointyLib, ... }:
let
  withDefaultNixpkgs =
    args:

    args
    // {
      inputs = args.inputs // {
        nixpkgs = args.nixpkgs or nixpkgs;
        self = args.inputs.self // {
          inputs = args.inputs.self.inputs // {
            nixpkgs = args.nixpkgs or nixpkgs;
          };
        };
      };
    };

  globalPaths = [
    "flake.nix"
    "pointy.nix"
    "templates"
    "packages"
    "main.pointy"
  ];

  loadRepo =
    args:
    let
      src = args.src or args.inputs.self.outPath;
      globalSrc = pointyLib.copyPaths { inherit src; paths = globalPaths; };
      cfg = import (globalSrc + "/pointy.nix") {
        lib = nixpkgs.lib;
        inputs = builtins.removeAttrs args.inputs [ "self" ];
      };
    in
    {
      inherit src globalSrc cfg;
      rev = args.inputs.self.rev or null;
    };
in
{
  mkFlake =
    args@{ inputs, modules ? [ ], ... }:
    flake-parts.lib.mkFlake (withDefaultNixpkgs (builtins.intersectAttrs { inherit inputs; nixpkgs = null; } args)) {
      imports = [ self.flakeModules.default ] ++ modules;

      systems = [ "x86_64-linux" ];

      _module.args.pointyRepo = loadRepo args;
    };
}
