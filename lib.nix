{
  self,
  nixpkgs,
  flake-parts,
  ...
}:
rec {
  types = import ./lib/types.nix { inherit nixpkgs; };

  renderStepConfig = (import ./lib/step-config.nix { inherit (nixpkgs) lib; inherit arityOf; }).renderStepConfig;

  api = {
    inherit
      mkFlake
      loadDir
      csvExtras
      fastqExtras
      ;
  };

  stepIdFromRef = stepRef: builtins.toString stepRef.step;

  mapSubjectRefs = f: arity: value:
    if arity == "many" then builtins.map f value else f value;

  loadDir =
    dir:
    builtins.readDir dir
    |> nixpkgs.lib.mapAttrs' (
      name: _: {
        name = nixpkgs.lib.removeSuffix ".nix" name;
        value = import (dir + "/${name}");
      }
    );

  # A producer parameter is a subject leaf or an array of them; every
  # other shape is wire data.
  arityOf =
    shape:
    {
      subject = "one";
      array = { subject = "many"; }.${shape.element.kind or "data"} or null;
    }
    .${shape.kind or "data"} or null;

  templateMeta =
    { templates, schema }:
    let
      # Fail on any other version here, never as a misrendered stepConfig.
      interfaces =
        assert
          schema.version or 0 == 3
          || throw "pointy templateMeta: the language provides argument-schema version ${builtins.toString (schema.version or 0)}; this stdlib reads version 3 (shape)";
        schema.interfaces;
    in
    builtins.mapAttrs (
      name: template:
      let
        contract = template.contract or (throw "pointy.template `${name}': contract missing");
        interface = contract.interface or (throw "pointy.template `${name}': contract.interface missing");
        iface = interfaces.${interface} or (throw "pointy.template `${name}': interface `${interface}' is not declared by the core schema");
        kind = template.pointy.type;
        specialArgs =
          if kind ? fileUpload then
            [ "uploaded" ]
          else if kind ? download then
            [ "downloaded" ]
          else
            [ ];

        params = builtins.map (
          sp:
          let
            shape = sp.shape or null;
          in
          {
            param = sp.parameter or (throw "pointy core schema: interface `${interface}' has a parameter without a name");
            arity = arityOf shape;
            inherit shape;
            default = sp.default or null;
            required = sp.required or true;
          }
        ) (iface.parameters or [ ]);
        paramNames = builtins.map (p: p.param) params;
      in
      {
        inherit interface params;
        output = contract.output or "out";
        subjectArity = builtins.listToAttrs (
          builtins.map (p: {
            name = p.param;
            value = p.arity;
          }) (builtins.filter (p: p.arity != null) params)
        );
        defaults = builtins.listToAttrs (
          builtins.map (p: {
            name = p.param;
            value = p.default;
          }) (builtins.filter (p: p.default != null) params)
        );
        knownArgs = paramNames ++ specialArgs;
        requiredArgs =
          builtins.map (p: p.param) (
            builtins.filter (p: p.required && p.arity != "many") params
          )
          ++ specialArgs;
      }
    ) templates;

  evalSteps =
    args@{
      stepDefs,
      templates,
      pkgs,
      srcFiles,
      metas,
      ...
    }:
    let
      steps = evalSteps args;
      compiledTemplates = builtins.mapAttrs (
        _: template:
        template.compile {
          lib = nixpkgs.lib;
          inherit pkgs;
          pointyLib = api;
        }
      ) templates;
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
        meta = metas.${type};
        template = templates.${type};
        templateKind = template.pointy.type;

        argRefs =
          nixpkgs.lib.optionalAttrs (templateKind ? fileUpload) {
            uploaded = value: pkgs.stdenv.mkDerivation {
              name = "store-ref";
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = value.hash;
              builder = pkgs.writeScript "fail" "exit 1";
            };
          }
          // nixpkgs.lib.optionalAttrs (templateKind ? download) {
            downloaded = value: pkgs.fetchurl {
              inherit (value) url hash;
            };
          }
          // builtins.mapAttrs (_: mapSubjectRefs (ref: steps.${stepIdFromRef ref})) meta.subjectArity;

        resolve = builtins.mapAttrs (argName: value: (argRefs.${argName} or (v: v)) value) args;

        srcDir = srcFiles + "/${id}";

        hasSrcDir =
          templateKind ? derivation
          && (templateKind.derivation.withSrcFiles or false)
          && builtins.pathExists srcDir;
        resolvedArgs =
          resolve
          // builtins.listToAttrs (
            builtins.map (p: {
              name = p.param;
              value = [ ];
            }) (builtins.filter (
              p: p.arity == "many" && !(resolve ? ${p.param})
            ) meta.params)
          );
        resolvedRequirements =
          if requirements != null then
            requirements
          else
            (template.requirements or (_: defaultRequirements)) resolvedArgs;
        unknown = nixpkgs.lib.subtractLists meta.knownArgs (builtins.attrNames args);
        missing = nixpkgs.lib.subtractLists (builtins.attrNames args) meta.requiredArgs;
        normalizedArgs =
          assert
            unknown == [ ]
            || throw "pointy.${type}: unknown arg(s): ${nixpkgs.lib.concatStringsSep ", " unknown}";
          assert
            missing == [ ]
            || throw "pointy.${type}: missing required arg(s): ${nixpkgs.lib.concatStringsSep ", " missing}";
          meta.defaults // resolvedArgs // {
            inherit id;
          };
        sourceOverride =
          if hasSrcDir then
            {
              unpackPhase = "find ${srcDir} -mindepth 1 -maxdepth 1 -print0 | xargs -0 -r -I{} ln -s {} .";
            }
          else
            {
              dontUnpack = true;
            };
        cfg = compiledTemplates.${type}.build {
          args = normalizedArgs;
          public = result;
        };
        result = pkgs.stdenv.mkDerivation (
          {
            pname = cfg.name or type;
            version = cfg.version or "";
          }
          // (cfg.env or { })
          // (cfg.mkDerivation or { })
          // sourceOverride
        );
      in
      result
      // {
        name = cfg.name or type;
        version = cfg.version or "";
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

  evalAutocomplete =
    { templates, pkgs, ... }:
    builtins.mapAttrs (
      _name: template:
      if template ? autocomplete then
        template.autocomplete {
          inherit pkgs;
          lib = nixpkgs.lib;
        }
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
      steps,
      projects,
      stepDefs,
      templates,
      ...
    }:
    let
      projects = evalProjects args;
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
    { stepDefs, templates, metas, ... }:
    let
      directDepsOf =
        id:
        let
          stepDef = stepDefs.${id};
          meta = metas.${stepDef.type} or { subjectArity = { }; };
          kind = templates.${stepDef.type}.pointy.type or { };
          deps = builtins.concatMap
            (value: builtins.map stepIdFromRef (nixpkgs.lib.toList value))
            (builtins.attrValues (nixpkgs.lib.intersectAttrs meta.subjectArity stepDef.args));
        in
        nixpkgs.lib.optional (kind ? derivation) deps |> builtins.concatLists;

      # The backend's RunStep graph walk consumes this as a set.
      transitiveDepsOf =
        id:
        builtins.filter (d: d != id) (
          builtins.map (n: n.key) (
            builtins.genericClosure {
              startSet = [ { key = id; } ];
              operator = node: builtins.map (d: { key = d; }) (directDepsOf node.key);
            }
          )
        );
    in
    builtins.mapAttrs (id: _: transitiveDepsOf id) stepDefs;

  # Scans `baseDrv` for CSV/TSV files and emits a meta.json per
  # directory with column metadata (type + nullable).
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

  # Scans `baseDrv` for FASTQ files and emits a meta.json per directory
  # with readCount; a line count not divisible by 4 fails the build.
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
