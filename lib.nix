{
  self,
  nixpkgs,
  flake-parts,
  ...
}:
pointyLib: rec {
  types = import ./lib/types.nix { inherit nixpkgs; };

  stepConfigPure = import ./lib/step-config.nix { };

  api = {
    inherit
      mkFlake
      loadDir
      csvExtras
      fastqExtras
      ;
  };

  stepIdFromRef = stepRef: builtins.toString stepRef.step;

  loadDir =
    dir:
    builtins.readDir dir
    |> nixpkgs.lib.mapAttrs' (
      name: _: {
        name = nixpkgs.lib.removeSuffix ".nix" name;
        value = import (dir + "/${name}");
      }
    );

  # ---- Contract / construction tables --------------------------------
  #
  # Parameter names, order, kind, shape, domain, default, and
  # requiredness come from the core schema.
  templateMeta =
    { templates, schema }:
    let
      interfaces = schema.interfaces or (throw "pointy.templateMeta: schema has no `interfaces` table");
    in
    builtins.mapAttrs (
      name: template:
      let
        contract = template.contract or (throw "pointy.template `${name}': contract missing");
        interface = contract.interface or (throw "pointy.template `${name}': contract.interface missing");
        iface = interfaces.${interface} or (throw "pointy.template `${name}': interface `${interface}' is not declared by the core schema");
        schemaParams = iface.parameters or [ ];
        bindings = template.bindings or { };
        builderArgs = template.builderArgs or { };
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
          {
            param = sp.parameter or (throw "pointy core schema: interface `${interface}' has a parameter without a name");
            kind = sp.kind or (throw "pointy core schema: parameter `${sp.parameter or "?"}' of `${interface}' has no kind");
            shape = sp.shape or null;
            default = sp.default or null;
            required = sp.required or true;
          }
        ) schemaParams;
        paramNames = builtins.map (p: p.param) params;
        problems =
          builtins.map
            (n: "unknown binding `${n}': not a core parameter of `${interface}' (did you mean builderArgs?)")
            (builtins.filter (n: !builtins.elem n paramNames) (builtins.attrNames bindings))
          ++ builtins.map
            (n: "builder argument `${n}' collides with a core parameter of `${interface}'")
            (builtins.filter (n: builtins.elem n paramNames) (builtins.attrNames builderArgs));
        _validated =
          if problems == [ ] then
            null
          else
            throw ("pointy.template `${name}': " + nixpkgs.lib.concatStringsSep "; " problems);

        builderDefaults = builtins.listToAttrs (
          builtins.map (n: {
            name = n;
            value = builderArgs.${n}.default;
          }) (builtins.filter (n: builderArgs.${n} ? default) (builtins.attrNames builderArgs))
        );
        requiredArgs =
          builtins.filter (n: !(builderArgs.${n} ? default)) (builtins.attrNames builderArgs)
          ++ specialArgs;
      in
      builtins.seq _validated {
        inherit params builderArgs;
        output = contract.output or "out";
        paramKinds = builtins.listToAttrs (
          builtins.map (p: {
            name = p.param;
            value = p.kind;
          }) params
        );
        coreDefaults = builtins.listToAttrs (
          builtins.map (p: {
            name = p.param;
            value = p.default;
          }) (builtins.filter (p: p.default != null) params)
        );
        coreRequiredNames = builtins.map (p: p.param) (
          builtins.filter (p: p.required && p.kind != "subjects") params
        );
        defaults = builderDefaults;
        knownArgs = paramNames ++ (builtins.attrNames builderArgs) ++ specialArgs;
        inherit requiredArgs;
      }
    ) templates;

  hostAdapter =
    templates:
    builtins.mapAttrs (
      name: template:
      let
        contract = template.contract or (throw "pointy.template `${name}': contract missing");
      in
      {
        interface = contract.interface or (throw "pointy.template `${name}': contract.interface missing");
        bindings = template.bindings or { };
        builderArgs = template.builderArgs or { };
        sortKey = template.sortKey or null;
        displayName = template.displayName or null;
        description = template.description or null;
        icon = template.icon or null;
        pointyType = template.pointy.type;
      }
    ) templates;

  renderStepConfig = stepConfigPure.renderStepConfig;

  # ---- Host schema derivation -----------------------------------------

  mkContractSchema =
    { pkgs, pointy, entryTree, modules }:
    let
      modulesJson = builtins.toFile "pointy-modules.json" (builtins.toJSON modules);
    in
    pkgs.runCommand "pointy-contract-schema" {
      ENTRY_TREE = entryTree;
      MODULES = modulesJson;
      nativeBuildInputs = [ pointy ];
      preferLocalBuild = true;
    } ''
      pointy check "$ENTRY_TREE/main.pointy" --modules "$MODULES" --schema > "$out"
    '';

  evalSteps =
    args@{
      stepDefs,
      templates,
      pkgs,
      srcFiles,
      contractSchema,
      ...
    }:
    let
      steps = evalSteps args;
      coreSchema = builtins.fromJSON (builtins.readFile (builtins.toString contractSchema));
      metas = templateMeta { inherit templates; schema = coreSchema; };
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

        resolveByKind = k: value:
          if k == "subject" || k == "listSubject" then
            steps.${stepIdFromRef value}
          else if k == "subjects" then
            builtins.map (ref: steps.${stepIdFromRef ref}) value
          else
            value;

        resolve = builtins.mapAttrs (
          argName: value:
          if meta.paramKinds ? ${argName} then
            resolveByKind meta.paramKinds.${argName} value
          else if templateKind ? fileUpload && argName == "uploaded" then
            pkgs.stdenv.mkDerivation {
              name = "store-ref";
              outputHashAlgo = "sha256";
              outputHashMode = "recursive";
              outputHash = value.hash;
              builder = pkgs.writeScript "fail" "exit 1";
            }
          else if templateKind ? download && argName == "downloaded" then
            pkgs.fetchurl {
              inherit (value) url hash;
            }
          else
            value
        ) args;

        srcDir = srcFiles + "/${id}";

        hasSrcDir =
          templateKind ? derivation
          && (templateKind.derivation.withSrcFiles or false)
          && builtins.pathExists srcDir;
      in
      let
        resolvedArgs =
          # The core's canonical empty acquisition is a plain empty array.
          resolve
          // builtins.listToAttrs (
            builtins.map (p: {
              name = p.param;
              value = [ ];
            }) (builtins.filter (
              p: p.kind == "subjects" && !(resolve ? ${p.param})
            ) meta.params)
          );
        resolvedRequirements =
          if requirements != null then
            requirements
          else
            (template.requirements or (_: defaultRequirements)) resolvedArgs;
        unknown = nixpkgs.lib.subtractLists meta.knownArgs (builtins.attrNames args);
        missing = nixpkgs.lib.subtractLists (builtins.attrNames args) meta.requiredArgs;
        missingCore = nixpkgs.lib.subtractLists (builtins.attrNames args) meta.coreRequiredNames;
        normalizedArgs =
          if unknown != [ ] then
            throw "pointy.${type}: unknown arg(s): ${nixpkgs.lib.concatStringsSep ", " unknown}"
          else if missing != [ ] then
            throw "pointy.${type}: missing required arg(s): ${nixpkgs.lib.concatStringsSep ", " missing}"
          else if missingCore != [ ] then
            throw "pointy.${type}: missing required core param(s): ${nixpkgs.lib.concatStringsSep ", " missingCore}"
          else
            meta.coreDefaults // meta.defaults // resolvedArgs // {
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
        # Templates read compile args as cfg.<param>.
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
    { stepDefs, templates, contractSchema, ... }:
    let
      schema = builtins.fromJSON (builtins.readFile (builtins.toString contractSchema));
      metas = templateMeta { inherit templates; schema = schema; };

      getDepIds =
        k: value:
        if k == "subject" || k == "listSubject" then
          [ (stepIdFromRef value) ]
        else if k == "subjects" then
          builtins.map stepIdFromRef value
        else
          [ ];

      directDepsOf =
        id:
        let
          stepDef = stepDefs.${id};
        in
        if
          templates ? ${stepDef.type}
          && metas ? ${stepDef.type}
          && templates.${stepDef.type}.pointy.type ? derivation
        then
          builtins.concatLists (
            builtins.attrValues (
              builtins.mapAttrs (
                argName: value:
                if metas.${stepDef.type}.paramKinds ? ${argName} then
                  getDepIds metas.${stepDef.type}.paramKinds.${argName} value
                else
                  [ ]
              ) stepDef.args
            )
          )
        else
          [ ];

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
        self.flakeModules.semantic
        userModule
      ];

      systems = [ "x86_64-linux" ];
    };
}
