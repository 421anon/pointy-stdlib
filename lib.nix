{
  self,
  nixpkgs,
  flake-parts,
  ...
}:
pointyLib: rec {
  types = import ./lib/types.nix { inherit nixpkgs; };

  # The pure (nixpkgs-free) core-schema merge + conformance module,
  # importable from nix-instantiate builders (stepConfig derivation and
  # the host conformance check) and from here.
  stepConfigPure = import ./lib/step-config.nix { };

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
  # Each template authors one plain-data table:
  #   contract = {
  #     interface = "..."; output = "...";
  #     parameters = [ { param = "...";
  #                      kind ? "value";        # adapter construction
  #                      default ? …; } ... ];  # optional; must match core
  #   };
  # Records, adapter argument maps, and compile args use `param`.
  #   bindings.<param> = { … };   # OPTIONAL presentation override
  #   builderArgs.<name> = { description; displayName ? null; default ? …;
  #     type = <explicit descriptor>; };   # adapter-owned editable inputs
  #
  # Semantic authority is the CORE argument schema (a derivation a host
  # realizes to register at eval, IFD per user policy; shape, finite
  # domain, default, and requiredness come from it): what the RAW
  # pipeline needs at evaluation time lives here as construction
  # metadata, not as copies in `bindings`:
  #   - `kind` (value/subject/subjects/listSubject) drives raw reference
  #     resolution, dependency discovery, and handle re-wrapping.  The
  #     host conformance check asserts it agrees with the core.
  #   - an authored `default` appears where the core declares one and
  #     agrees with it; otherwise the schema supplies the effective value.
  # `bindings` provides presentation overrides (host-time, build input):
  # widgets, dropdowns, reference types, labels, autocomplete.  Shape,
  # domain, default, and requiredness come from the core; unknown
  # override names reject.
  #
  # Returns per template:
  #   params        : [ { param, kind } ] in contract order
  #   paramKinds    : param name -> kind                       (resolution;
  #                   records are keyed by param)
  #   defaults      : authored defaults for builder args
  #   builderArgs   : name -> authored builder arg table
  #   knownArgs     : every param name a record may carry (incl. the
  #                   upload/download transport names)
  templateMeta =
    templates:
    builtins.mapAttrs (
      name: template:
      let
        validKinds = [
          "value"
          "subject"
          "subjects"
          "listSubject"
        ];
        contract = template.contract or (throw "pointy.template `${name}': contract missing");
        interface = contract.interface or (throw "pointy.template `${name}': contract.interface missing");
        pairs = contract.parameters or (throw "pointy.template `${name}': contract.parameters missing");
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
          pair:
          let
            param = pair.param or (throw "pointy.template `${name}': contract.parameters entry is missing `param`");
            pkind = pair.kind or "value";
            _entryShape =
              if pair ? option then
                throw "pointy.template `${name}.${param}': contract.parameters entry shape is { param; kind ? }"
              else
                null;
            _kindValid =
              if builtins.elem pkind validKinds then
                null
              else
                throw "pointy.template `${name}.${param}': unknown kind `${pkind}' (expected one of ${nixpkgs.lib.concatStringsSep ", " validKinds})";
          in
          {
            inherit param;
            kind = pkind;
          }
        ) pairs;
        paramNames = builtins.map (p: p.param) params;
        problems =
          builtins.map
            (n: "duplicate contract parameter `${n}`")
            (builtins.filter (n: builtins.length (builtins.filter (x: x == n) paramNames) > 1) (nixpkgs.lib.unique paramNames))
          ++ builtins.map
            (n: "unknown binding `${n}': not a contract parameter (did you mean builderArgs?)")
            (builtins.filter (n: !builtins.elem n paramNames) (builtins.attrNames bindings))
          ++ builtins.map
            (n: "builder argument `${n}' collides with a contract parameter")
            (builtins.filter (n: builtins.elem n paramNames) (builtins.attrNames builderArgs));
        _validated =
          if problems == [ ] then
            null
          else
            throw ("pointy.template `${name}': " + nixpkgs.lib.concatStringsSep "; " problems);

        semanticDefaults = { };
        builderDefaults = builtins.listToAttrs (
          builtins.map (n: {
            name = n;
            value = builderArgs.${n}.default;
          }) (builtins.filter (n: builderArgs.${n} ? default) (builtins.attrNames builderArgs))
        );
        # The raw pipeline reads from the record the transport
        # upload/download values and builder args lacking an adapter
        # default.  Semantic parameters are not required at eval: core
        # defaults (value params) and the canonical empty acquisition
        # lists (producer params) are supplied by the
        # core-authoritative normalization boundary — value defaults in
        # the step builder from the schema, empty producers structurally
        # here — so defaultless saved records keep building.
        requiredArgs =
          builtins.filter (n: !(builderArgs.${n} ? default)) (builtins.attrNames builderArgs)
          ++ specialArgs;
      in
      {
        inherit params builderArgs;
        paramKinds = builtins.listToAttrs (
          builtins.map (p: {
            name = p.param;
            value = p.kind;
          }) params
        );
        defaults = builderDefaults;
        knownArgs = paramNames ++ (builtins.attrNames builderArgs) ++ specialArgs;
        inherit requiredArgs;
      }
    ) templates;

  # Serialize the host's template tables into the plain-data `adapter`
  # document the stepConfig merge and the conformance check consume as a
  # build input.  `parameters` carries the construction metadata, the
  # raw `bindings` (presentation overrides) pass through to be validated
  # and merged against the core schema.
  hostAdapter =
    templates:
    builtins.mapAttrs (
      name: template:
      let
        contract = template.contract or (throw "pointy.template `${name}': contract missing");
        parameters = builtins.map (
          pair:
          let
            param = pair.param or (throw "pointy.template `${name}': contract.parameters entry is missing `param`");
            _entryShape =
              if pair ? option then
                throw "pointy.template `${name}.${param}': contract.parameters entry shape is { param; kind ? }"
              else
                null;
          in
          {
            inherit param;
            kind = pair.kind or "value";
            default = pair.default or null;
          }
        ) (contract.parameters or [ ]);
      in
      {
        interface = contract.interface;
        inherit parameters;
        bindings = template.bindings or { };
        builderArgs = template.builderArgs or { };
        sortKey = template.sortKey or null;
        displayName = template.displayName or null;
        description = template.description or null;
        icon = template.icon or null;
        pointyType = template.pointy.type;
      }
    ) templates;

  # The conformance + merge surface exposed to hosts.  renderStepConfig
  # merges the core schema with the host adapter into the frontend's
  # stepConfig document; validateHostAdapter reports adapter-vs-schema
  # violations for the flake-check gate.
  renderStepConfig = stepConfigPure.renderStepConfig;
  validateHostAdapter = stepConfigPure.validateHostAdapter;

  # ---- Host schema + stepConfig derivations ---------------------------
  #
  # The core argument schema is per-host, generated by the core over the
  # host's OWN enrolled sources (`pointy check --schema`); the schema is
  # a derivation output.  It is realized and read at evaluation
  # (user-authorized IFD) for construction defaults and requiredness,
  # and consumed as a build input by the stepConfig derivation and the
  # conformance check.  Produced fresh per host; not authored by hand.

  # The canonical argument schema of one host corpus (a file output).
  mkContractSchema =
    { pkgs, pointy, entryTree, modules }:
    let
      modulesJson = builtins.toFile "pointy-modules.json" (builtins.toJSON modules);
    in
    pkgs.runCommand "pointy-contract-schema" {
      inherit pointy;
      ENTRY_TREE = entryTree;
      MODULES = modulesJson;
      nativeBuildInputs = [ pointy ];
      preferLocalBuild = true;
    } ''
      pointy check "$ENTRY_TREE/main.pointy" --modules "$MODULES" --schema > "$out"
    '';

  # The host-generated stepConfig document: the core schema merged with
  # the host's presentation overrides (bindings), rendered by the pure
  # merge module and emitted as a derivation.  The backend serves the
  # realized file.
  mkStepConfig =
    { pkgs, schema, templates }:
    let
      adapter = builtins.toFile "pointy-adapter.json" (builtins.toJSON (hostAdapter templates));
    in
    pkgs.runCommand "pointy-step-config" {
      inherit schema adapter;
      nativeBuildInputs = [ pkgs.nix ];
      preferLocalBuild = true;
      HOME = "/tmp";
      NIX_STATE_DIR = "/tmp/nix-state";
      NIX_LOG_DIR = "/tmp/nix-log";
    } ''
      nix-instantiate --eval --strict --json \
        --argstr schemaPath "$schema" \
        --argstr adapterPath "$adapter" \
        --argstr stepConfigPath ${./lib/step-config.nix} \
        ${./lib/step-config-render.nix} > "$out"
    '';

  # The host conformance gate: a check derivation (never an output) that
  # requires the adapter tables (parameter set, kinds, construction
  # defaults, bindings, builderArgs) to merge cleanly and agree with the
  # core schema.  Fails with every violation; the probes guarantee the
  # gate is not vacuous.
  checkHostConformance =
    { pkgs, schema, adapter }:
    let
      adapterJson = builtins.toFile "pointy-adapter.json" (builtins.toJSON adapter);
    in
    pkgs.runCommand "pointy-host-conformance" {
      inherit schema adapterJson;
      nativeBuildInputs = [ pkgs.nix pkgs.jq ];
      preferLocalBuild = true;
      HOME = "/tmp";
      NIX_STATE_DIR = "/tmp/nix-state";
      NIX_LOG_DIR = "/tmp/nix-log";
    } ''
      set -euo pipefail
      nix-instantiate --eval --strict --json \
        --argstr schemaPath "$schema" \
        --argstr adapterPath "$adapterJson" \
        --argstr stepConfigPath ${./lib/step-config.nix} \
        ${./lib/step-config-validate.nix} > problems.json
      if [ "$(jq 'length' problems.json)" != "0" ]; then
        echo "pointy host conformance failed:"
        jq -r '.[]' problems.json
        exit 1
      fi
      echo "ok: host adapter merges cleanly with the core schema"
      touch "$out"
    '';

  evalSteps =
    args@{
      stepDefs,
      templates,
      pkgs,
      srcFiles,
      contractSchema ? null,
      ...
    }:
    let
      steps = evalSteps args;
      metas = templateMeta templates;
      compiledTemplates = builtins.mapAttrs (
        _: template:
        template.compile {
          lib = nixpkgs.lib;
          inherit pkgs pointyLib;
        }
      ) templates;
      defaultRequirements = {
        ram = "1G";
        cpu = 1;
        ior = "0";
        iow = "0";
      };
      # The core argument schema, realized and read at EVAL (IFD,
      # user-approved): semantic defaults and requiredness come from it.
      # Realized once; every step reads the same value.
      coreSchema =
        if contractSchema != null then
          builtins.fromJSON (builtins.readFile (builtins.toString contractSchema))
        else
          null;
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

        # Kind-driven reference resolution: contract parameters of kind
        # subject/subjects/listSubject carry `{step = id;}` references
        # that resolve to sibling raw derivations; uploads/downloads
        # resolve through their fixed-output fetch rules; everything
        # else passes through unchanged.
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
          # Producer parameters (subject/subjects/listSubject kinds) that
          # the record omits get the canonical EMPTY acquisition list
          # here — a structural default, not a copied core value (the
          # core spell-it-as-@subjects = [ ]@ envelope).  Single-subject
          # producers with no record value stay missing and are rejected
          # by the core check, never silently empty.
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
        # Adapter-level requiredness: transport uploads/downloads and
        # builder args lacking a default.  Semantic requiredness comes
        # from the core schema below (user-approved IFD).
        missing = nixpkgs.lib.subtractLists (builtins.attrNames args) meta.requiredArgs;
        # The core schema realized + read at EVAL (IFD, user-approved):
        # canonical defaults and requiredness.
        iface = (coreSchema.interfaces or { }).${template.contract.interface} or null;
        coreDefaults =
          builtins.listToAttrs (
            builtins.map (
              sp:
              {
                name = sp.parameter;
                value = sp.default;
              }
            ) (builtins.filter (sp: sp.default != null) (if iface != null then iface.parameters or [ ] else [ ]))
          );
        coreRequiredNames =
          builtins.map (
            sp: sp.parameter
          ) (builtins.filter (sp: sp.required or true) (if iface != null then iface.parameters or [ ] else [ ]));
        missingCore = nixpkgs.lib.subtractLists (builtins.attrNames args) coreRequiredNames;
        normalizedArgs =
          if unknown != [ ] then
            throw "pointy.${type}: unknown arg(s): ${nixpkgs.lib.concatStringsSep ", " unknown}"
          else if missing != [ ] then
            throw "pointy.${type}: missing required arg(s): ${nixpkgs.lib.concatStringsSep ", " missing}"
          else if missingCore != [ ] then
            throw "pointy.${type}: missing required core param(s): ${nixpkgs.lib.concatStringsSep ", " missingCore}"
          else
            # Schema defaults under the raw record values.
            coreDefaults // resolvedArgs // {
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
        # Records are canonical: normalizedArgs is param-keyed and the
        # template's compile block reads cfg.<param> directly.
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
    { stepDefs, templates, ... }:
    let
      metas = templateMeta templates;

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
        self.flakeModules.semantic
        userModule
      ];

      systems = [ "x86_64-linux" ];
    };
}
