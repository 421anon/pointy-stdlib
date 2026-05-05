{
  self,
  nixpkgs,
  dream2nix,
  flake-parts,
}:
pointyLib: rec {
  types = import ./lib/types.nix { inherit nixpkgs; };

  stepIdFromRef = stepRef: builtins.toString stepRef.step;
  isStepArg = argType: argType ? step;
  isStepListArg = argType: argType ? list && argType.list ? step;

  libModule =
    { lib, ... }:
    {
      options._pointy.lib = nixpkgs.lib.mkOption { type = lib.types.attrs; };
      config._pointy.lib = pointyLib;
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
      srcFiles,
      ...
    }:
    let
      steps = evalSteps args;
      stepConfig = evalStepConfig { inherit templates; };
    in
    stepDefs
    |> builtins.mapAttrs (
      id:
      { type, args, ... }:
      let
        resolveArg =
          argType: value:
          if isStepArg argType then
            steps.${stepIdFromRef value}
          else if isStepListArg argType then
            builtins.map (stepRef: steps.${stepIdFromRef stepRef}) value
          else
            value;

        resolve = builtins.mapAttrs (
          argName: value:
          if
            stepConfig ? ${type}
            && stepConfig.${type}.type ? derivation
            && stepConfig.${type}.type.derivation.args ? ${argName}
          then
            resolveArg stepConfig.${type}.type.derivation.args.${argName}.type value
          else if stepConfig ? ${type} && stepConfig.${type}.type ? fileUpload && argName == "uploaded" then
            pkgs.stdenv.mkDerivation {
              name = "store-ref";
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = value.hash;
              builder = pkgs.writeScript "fail" "exit 1";
            }
          else if stepConfig ? ${type} && stepConfig.${type}.type ? download && argName == "downloaded" then
            pkgs.fetchurl { inherit (value) url hash; }
          else
            value
        );

        srcDir = srcFiles + "/${id}";

        hasSrcDir =
          stepConfig ? ${type}
          && stepConfig.${type}.type ? derivation
          && (stepConfig.${type}.type.derivation.withSrcFiles or false)
          && builtins.pathExists srcDir;

      in
      dream2nix.lib.evalModules {
        packageSets.nixpkgs = pkgs;
        specialArgs = { inherit pkgs; };
        modules = [
          libModule
          templates.${type}.module
          {
            pointy.${type} = resolve args // {
              inherit id;
            };
          }
        ]
        ++ (
          if hasSrcDir then
            [
              {
                mkDerivation.unpackPhase = "find ${srcDir} -mindepth 1 -maxdepth 1 -print0 | xargs -0 -r -I{} ln -s {} .";
              }
            ]
          else
            [ { mkDerivation.dontUnpack = true; } ]
        );
      }
    );

  evalStepConfig =
    { templates, ... }:
    (dream2nix.lib.evalModules {
      packageSets.nixpkgs = nixpkgs.legacyPackages.x86_64-linux;
      modules = [ libModule ] ++ builtins.map (t: t.module) (builtins.attrValues templates);
      raw = true;
    }).options.pointy
    |> builtins.mapAttrs (
      name: opt:
      let
        template = templates.${name};
        type = template.pointy.type;
      in
      {
        sortKey = template.sortKey or null;
        displayName = template.displayName or null;
        description = template.description or null;
        type =
          if type ? derivation then
            {
              derivation = type.derivation // {
                args =
                  opt
                  |> nixpkgs.lib.filterAttrs (_: optValue: optValue.visible or true)
                  |> builtins.mapAttrs (
                    _:
                    { type, ... }:
                    {
                      inherit (type.description) type description;
                      displayName = type.description.displayName or null;
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

  evalDependencies =
    { stepDefs, templates, ... }:
    let
      stepConfig = evalStepConfig { inherit templates; };

      getDepIds =
        argType: value:
        if isStepArg argType then
          [ (stepIdFromRef value) ]
        else if isStepListArg argType then
          builtins.map stepIdFromRef value
        else
          [ ];

      directDepsOf =
        id:
        let
          stepDef = stepDefs.${id};
          sc = stepConfig.${stepDef.type} or null;
        in
        if sc != null && sc.type ? derivation then
          builtins.concatLists (
            builtins.attrValues (
              builtins.mapAttrs (
                argName: value:
                if sc.type.derivation.args ? ${argName} then
                  getDepIds sc.type.derivation.args.${argName}.type value
                else
                  [ ]
              ) stepDef.args
            )
          )
        else
          [ ];

      visit =
        depId: visited:
        if builtins.elem depId visited then
          {
            result = [ ];
            visited = visited;
          }
        else
          let
            deps = directDepsOf depId;
            newVisited = visited ++ [ depId ];
            afterDeps =
              builtins.foldl'
                (
                  acc: d:
                  let
                    sub = visit d acc.visited;
                  in
                  {
                    result = acc.result ++ sub.result;
                    visited = sub.visited;
                  }
                )
                {
                  result = [ ];
                  visited = newVisited;
                }
                deps;
          in
          {
            result = afterDeps.result ++ [ depId ];
            visited = afterDeps.visited;
          };

      transitiveDepsOf =
        id:
        (builtins.foldl'
          (
            acc: dep:
            let
              sub = visit dep acc.visited;
            in
            {
              result = acc.result ++ sub.result;
              visited = sub.visited;
            }
          )
          {
            result = [ ];
            visited = [ id ];
          }
          (directDepsOf id)
        ).result;
    in
    builtins.mapAttrs (id: _: transitiveDepsOf id) stepDefs;

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
