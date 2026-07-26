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
      compiledModules = builtins.mapAttrs (_typeName: template:
        dream2nix.lib.evalModules {
          packageSets.nixpkgs = pkgs;
          specialArgs = { inherit pkgs pointyLib dream2nix; };
          modules = [
            {
              config._module.residualModules = [
                dream2nix.modules.dream2nix.mkDerivation
              ];
            }
            libModule
            template.module
          ];
          raw = true;
        }
      ) templates;
      steps = evalSteps args;
      stepConfig = evalStepConfig { inherit templates; };
      defaultRequirements = {
        ram = "1G";
        cpu = 1;
        ior = "0";
        iow = "0";
      };
    in
    stepDefs
    |> builtins.mapAttrs (
      id:
      {
        type,
        args,
        requirements ? null,
        ...
      }:
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
      let
        resolvedArgs = resolve args;
        resolvedRequirements =
          if requirements != null then
            requirements
          else
            (templates.${type}.requirements or (_: defaultRequirements)) resolvedArgs;
        result = compiledModules.${type}.instantiate [
          {
            config = { pointy.${type} = resolvedArgs // { inherit id; }; } // (if hasSrcDir then {
              mkDerivation.unpackPhase = "find ${srcDir} -mindepth 1 -maxdepth 1 -print0 | xargs -0 -r -I{} ln -s {} .";
            } else {
              mkDerivation.dontUnpack = true;
            });
          }
        ];
      in
      result
      // {
        requirements = resolvedRequirements;
        meta = (result.meta or { }) // {
          pointy = (result.meta.pointy or { }) // {
            inherit id type;
            requirements = resolvedRequirements;
            args = resolvedArgs;
          };
        };
      }
    );

  evalStepConfig =
    { templates, ... }:
    (dream2nix.lib.evalModules {
      packageSets.nixpkgs = nixpkgs.legacyPackages.x86_64-linux;
      specialArgs = { inherit pointyLib; };
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

  evalAutocomplete =
    { templates, pkgs, ... }:
    builtins.mapAttrs (
      _name: template:
      if template ? autocomplete then
        template.autocomplete { inherit pkgs; lib = nixpkgs.lib; }
      else
        { }
    ) templates;

  evalPresets =
    { templates, presets, ... }:
    builtins.mapAttrs (
      name: preset:
      let
        unknown = builtins.filter (t: !(templates ? ${t})) preset.templates;
      in
      if unknown != [ ] then
        throw "Preset `${name}` references unknown templates: ${nixpkgs.lib.concatStringsSep ", " unknown}."
      else
        preset
    ) presets;

  evalProjects =
    args@{
      projects,
      templates,
      presets ? { },
      ...
    }:
    let
      stepDefs = evalStepDefs args;
    in
    builtins.mapAttrs (
      id: proj:
      let
        hasPreset = proj.preset != null;
        hasTemplates = proj.templates != null;
        unknownTemplates =
          if hasTemplates then builtins.filter (t: !(templates ? ${t})) proj.templates else [ ];
        knownSteps = builtins.filter (s: stepDefs ? ${toString s.id}) proj.steps;
        unknownStepIds = map (s: toString s.id) (
          builtins.filter (s: !(stepDefs ? ${toString s.id})) proj.steps
        );
        validationErrors =
          nixpkgs.lib.optional (
            hasPreset && !(presets ? ${proj.preset})
          ) "Unknown preset `${proj.preset}`. Pick another preset in the edit form."
          ++
            nixpkgs.lib.optional (hasTemplates && unknownTemplates != [ ])
              "Unknown templates: ${nixpkgs.lib.concatStringsSep ", " unknownTemplates}. Remove them in the edit form."
          ++ nixpkgs.lib.optional (
            unknownStepIds != [ ]
          ) "Unknown step ids: ${nixpkgs.lib.concatStringsSep ", " unknownStepIds}.";
      in
      if !hasPreset && !hasTemplates then
        throw "Project `${id}` must define either `preset` or `templates`."
      else if hasPreset && hasTemplates then
        throw "Project `${id}` cannot define both `preset` and `templates`."
      else
        proj
        // {
          id = nixpkgs.lib.toIntBase10 id;
          steps = map (step: {
            def = stepDefs.${toString step.id};
            inherit (step) hidden sortKey;
          }) knownSteps;
          inherit validationErrors;
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

  # Build a derivation that scans `baseDrv` for CSV/TSV files and emits a
  # meta.json per directory containing column metadata (type + nullable).
  # Uses duckdb sniff_csv for type detection and UNPIVOT for nullability.
  # `baseDrv` is the step output derivation.
  csvExtras =
    {
      pkgs,
      baseDrv,
      requirements ? {
        ram = "2G";
        cpu = 2;
        ior = "0";
        iow = "0";
      },
    }:
    pkgs.runCommand "csv-extras" { } ''
      bash ${./lib/csv-extras.sh} \
        ${pkgs.duckdb}/bin/duckdb \
        ${pkgs.jq}/bin/jq \
        "${baseDrv}" \
        "$out"
    ''
    // { inherit requirements; };

  # Build a derivation that scans `baseDrv` for FASTQ files (*.fastq,
  # *.fq, *.fastq.gz, *.fq.gz) and emits a meta.json per directory with
  # readCount.  Fails the build when a file's line count is not divisible by 4.
  fastqExtras =
    {
      pkgs,
      baseDrv,
      requirements ? {
        ram = "1G";
        cpu = 1;
        ior = "0";
        iow = "0";
      },
    }:
    pkgs.runCommand "fastq-extras" { } ''
      bash ${./lib/fastq-extras.sh} \
        "${baseDrv}" \
        "$out"
    ''
    // { inherit requirements; };

  # Merge multiple extras derivations into one.  Each derivation is a
  # directory tree of meta.json files (keyed by child file name).  Duplicate
  # child-file keys within the same directory fail the build.
  mergeExtras =
    {
      pkgs,
      extras,
      requirements ? {
        ram = "1G";
        cpu = 1;
        ior = "0";
        iow = "0";
      },
    }:
    let
      srcs = nixpkgs.lib.concatStringsSep " " (map (e: "\"${e}\"" ) extras);
    in
    pkgs.runCommand "merged-extras" { } ''
      bash ${./lib/merge-extras.sh} ${pkgs.jq}/bin/jq "$out" ${srcs}
    ''
    // { inherit requirements; };

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
