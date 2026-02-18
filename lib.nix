{
  self,
  nixpkgs,
  dream2nix,
  flake-parts,
}:
trotterLib: rec {
  types = import ./lib/types.nix { inherit nixpkgs; };

  libModule =
    { lib, ... }:
    {
      options._trotter.lib = nixpkgs.lib.mkOption { type = lib.types.attrs; };
      config._trotter.lib = trotterLib;
    };

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
      ...
    }:
    let
      steps = evalSteps args;
      stepConfig = evalStepConfig { inherit templates; };
      mkStoreReference =
        hash:
        pkgs.stdenv.mkDerivation {
          name = "store-ref";
          outputHashAlgo = "sha256";
          outputHashMode = "recursive";
          outputHash = hash;
          builder = pkgs.writeScript "fail" "exit 1";
        };
    in
    stepDefs
    |> builtins.mapAttrs (
      id:
      { type, args, ... }:
      let
        resolve = builtins.mapAttrs (
          argName: value:
          if
            stepConfig ? ${type}
            && stepConfig.${type}.type ? derivation
            && stepConfig.${type}.type.derivation.args ? ${argName}
            && stepConfig.${type}.type.derivation.args.${argName}.type ? step
          then
            steps.${builtins.toString value.step}
          else if stepConfig ? ${type} && stepConfig.${type}.type ? fileUpload && argName == "uploaded" then
            mkStoreReference value.hash
          else
            value
        );
      in
      dream2nix.lib.evalModules {
        packageSets.nixpkgs = pkgs;
        modules = [
          libModule
          {
            trotter.${type} = resolve args // {
              inherit id;
            };
          }
          templates.${type}.module
        ];
      }
    );

  evalStepConfig =
    { templates, ... }:
    (dream2nix.lib.evalModules {
      packageSets.nixpkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ libModule ] ++ builtins.map (t: t.module) (builtins.attrValues templates);
      raw = true;
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

  evalProjects =
    args@{ projects, ... }:
    let
      stepDefs = evalStepDefs args;
    in
    builtins.mapAttrs (
      id: proj:
      proj
      // {
        id = nixpkgs.lib.toIntBase10 id;
        steps = map (step: {
          def = stepDefs.${toString step.id};
          inherit (step) hidden sortKey;
        }) proj.steps;
      }
    ) projects;

  evalStepDefs =
    { stepDefs, ... }:
    builtins.mapAttrs (id: stepDef: stepDef // { id = nixpkgs.lib.toIntBase10 id; }) stepDefs;

  evalProjectOutPaths =
    args@{
      pkgs,
      projects,
      stepDefs,
      templates,
      ...
    }:
    let
      projects = evalProjects args;
      steps = evalSteps args;
    in
    builtins.mapAttrs (
      _: proj:
      builtins.listToAttrs
      <| map (
        step:
        let
          id = toString step.def.id;
        in
        {
          name = id;
          value =
            let
              tr = builtins.tryEval steps.${id}.outPath;
            in
            if tr.success then tr.value else "/invalid";
        }
      ) proj.steps

    ) projects;

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
