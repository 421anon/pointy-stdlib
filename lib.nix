inputs@{
  self,
  nixpkgs,
  dream2nix,
  flake-parts,
}:
rec {
  types.trotter.step =
    allowedTypes: description:
    (nixpkgs.lib.types.addCheck nixpkgs.lib.types.package (
      pkg: nixpkgs.lib.lists.any (t: pkg.meta.trotter.type == t) allowedTypes
    ))
    // {
      description = {
        type.step = { inherit allowedTypes; };
        inherit description;
        __toString = _: "TStep [" + builtins.toString allowedTypes + "]";
      };
    };

  types.stringWithDescription =
    description:
    nixpkgs.lib.types.str
    // {
      description = {
        type.string = { };
        inherit description;
        __toString = _: "TString";
      };
    };

  trotterLib = import ./lib.nix inputs;

  loadDir =
    dir:
    builtins.readDir dir
    |> nixpkgs.lib.mapAttrs' (
      name: _: {
        name = nixpkgs.lib.removeSuffix ".nix" name;
        value = import (dir + "/${name}");
      }
    );

  evalSteps =
    args@{
      stepDefs,
      templates,
      pkgs,
    }:
    let
      steps = evalSteps args;
      options = evalStepConfig { inherit templates; };
    in
    stepDefs
    |> builtins.mapAttrs (
      id:
      { type, args, ... }:
      let
        resolve = builtins.mapAttrs (
          argName: value:
          if
            options ? ${type}
            && options.${type}.type ? derivation
            && options.${type}.type.derivation.args ? ${argName}
            && options.${type}.type.derivation.args.${argName}.type ? step
          then
            steps.${builtins.toString value}
          else
            value
        );
      in
      dream2nix.lib.evalModules {
        packageSets.nixpkgs = pkgs;
        modules = [
          {
            trotter.${type} = resolve args // {
              inherit id;
            };
          }
          templates.${type}.module
        ];
        specialArgs = {
          inherit steps trotterLib;
        };
      }
    );

  evalStepConfig =
    { templates }:
    (dream2nix.lib.evalModules {
      packageSets.nixpkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = builtins.map (t: t.module) (builtins.attrValues templates);
      raw = true;
      specialArgs = { inherit trotterLib; };
    }).options.trotter
    |> builtins.mapAttrs (
      name: opt:
      let
        type = templates.${name}.trotter.type;
      in
      {
        type =
          if type ? derivation then
            type
            // {
              derivation = type.derivation // {
                args =
                  opt
                  |> nixpkgs.lib.filterAttrs (_: optValue: optValue.visible or true)
                  |> builtins.mapAttrs (
                    _:
                    { type, ... }:
                    {
                      inherit (type.description) type description;
                    }
                  );
              };
            }
          else
            type;
      }
    );

  mkFlake =
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
    in
    args: userModule:
    flake-parts.lib.mkFlake (withDefaultNixpkgs args) {
      imports = [
        self.flakeModules.default
        userModule
      ];

      systems = [ "x86_64-linux" ];
    };
}
