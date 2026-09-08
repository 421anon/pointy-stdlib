# Semantic host adapter: one pointy-language contract layer over the raw
# steps.  Always active: the stdlib itself stays language-agnostic — the
# host supplies the pointy language flake and its build pkgs.
#
# The host config is exactly:
#   semantic = {
#     language = inputs.pointy-stdlib.language;   # OPTIONAL: defaults to the
#                                       # stdlib's own pointy-lang input; must
#                                       # expose lib.<system> and
#                                       # pointyScanners.<system> when overridden
#     pkgs = pkgs;                      # the pkgs the raw steps build with
#     source = ./main.pointy;
#     modules.csv = "ext/csv.pointy";   # logical name -> source-relative path
#     scanners.csv = { };               # name -> bundle overrides ({} = take
#     }                                 #   language.pointyScanners.<system>.<name>)
#
# Templates carry the contract convention:
#   contract = {
#     interface = "...";                # the struct applied per record
#     output = "...";                   # the exact named output certified
#     parameters = [                    # projection, in order
#       { param = "..."; kind ? "value"; } ...
#     ];
#   };
#   bindings.<param> = { ... }          # presentation/default overlay
#   builderArgs.<name> = { ... }        # adapter-owned editable inputs
# The template table and its kinds/defaults form the adapter's side of
# the host merge; the conformance check compares them against the core's
# interface descriptions and declared defaults (as build-time inputs).
#
# The kernel is computed at flake level (pkgs comes from the host option);
# derivation views land in packages.pointy, typed `package`.
{ pointyLib, pointy-lang }:
top:
let
  lib = top.lib;
  sel = top.config.pointy.semantic;
in
{
  options.pointy.semantic = {
    language = lib.mkOption {
      type = lib.types.raw;
      default = pointy-lang;
      description = "The pointy language flake (semantic core + scanner bundles). Defaults to this stdlib flake's own `pointy-lang` input; pass a fork or a separately pinned flake to override.";
    };
    pkgs = lib.mkOption {
      type = lib.types.raw;
      description = "The pkgs to build raw steps and sources with. Required.";
    };
    source = lib.mkOption {
      type = lib.types.raw;
      description = "Entry program source (conventionally main.pointy). Required.";
    };
    modules = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Logical module name -> source-relative path the entry program imports it at.";
    };
    scanners = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Observation-interface name -> optional bundle overrides ({ interface; program }) over the language flake's pointyScanners.<system>.<name>.";
    };
    result = lib.mkOption {
      internal = true;
      type = lib.types.attrs;
      default = { };
      description = "Computed semantic kernel; merged into flake.pointy by the default module.";
    };
  };

  config = (
    let
      # Per-system kernels are fixed by mkFlake (systems = [ "x86_64-linux" ]).
      system = "x86_64-linux";
      pkgs = sel.pkgs;
      langLib = sel.language.lib.${system};

      resolveBundle = name: spec:
        let
          bundleScope = sel.language.pointyScanners.${system};
          bundle =
            if builtins.hasAttr name bundleScope then
              bundleScope.${name}
            else
              throw "pointy.semantic: no scanner bundle `${name}' in the language flake's pointyScanners.${system}";
        in
        {
          interface = spec.interface or bundle.interface;
          program = spec.program or bundle.program;
        };

      resolvedScanners = builtins.mapAttrs resolveBundle sel.scanners;

      # Structural projection composed from a template's declared
      # contract.parameters over the canonical call args: each projected
      # argument is read from args.<param> (records and call args are
      # param-keyed).  The list is the projection order.
      projectionOf = contract: args:
        builtins.listToAttrs (builtins.map (pair: {
          name = pair.param;
          value = args.${pair.param};
        }) contract.parameters);

      templates = top.config.pointy.templates;
      records = top.config.pointy.stepDefs;
      # One authored table per template (parameters, kinds, defaults,
      # builder args), validated at the first consumer.
      metas = pointyLib.templateMeta templates;

      # Same evaluation the default module publishes as packages.pointy.steps
      # (identical derivations — same function, args, pkgs), computed here
      # because the kernel needs it at flake level.
      steps = pointyLib.evalSteps (top.config.pointy // { inherit pkgs; });

      # ---- Semantic sources --------------------------------------------
      #
      # entryTree assembles the minimal source-relative layout the entry
      # program's imports rely on: main.pointy at the root plus every
      # enrolled module copied to its declared relative path, sourced
      # from its scanner bundle interface.  Copied, not symlinked: the
      # core's containment audit rejects symlink escapes, and these
      # files feed the model chain.
      moduleSources = builtins.mapAttrs (name: rel:
        {
          inherit rel;
          src = resolvedScanners.${name}.interface
            or (throw "pointy.semantic: module `${name}' has no same-named scanner bundle to source its interface from");
        }
      ) sel.modules;

      moduleList = lib.imap0 (i: m: m // { idx = i; }) (builtins.attrValues moduleSources);

      entryTree =
        pkgs.runCommand "pointy-entry-sources"
          (builtins.listToAttrs (
            builtins.map (m: {
              name = "pointyModule${toString m.idx}";
              value = m.src;
            }) moduleList
          ))
          (
            ''
              mkdir -p "$out"
              cp ${sel.source} "$out/main.pointy"
            ''
            + builtins.concatStringsSep "\n" (
              builtins.map (m: ''
                mkdir -p "$out/${builtins.dirOf m.rel}"
                cp "$pointyModule${toString m.idx}" "$out/${m.rel}"
              '') moduleList
            )
          );
      entrySource = "${entryTree}/main.pointy";
      entryModules = builtins.mapAttrs (_: m: "${entryTree}/${m.rel}") moduleSources;

      # The exact interface path must be a direct inputSrc of the
      # certificate derivation (certifier coverage gate); snap it as a
      # standalone single-file source.
      scannerBundles = builtins.mapAttrs (_: b: {
        interface = builtins.path {
          path = b.interface;
          name = "pointy-scanner-interface";
        };
        program = b.program;
      }) resolvedScanners;

      sharedModel = langLib.mkContractModel {
        source = entrySource;
        modules = entryModules;
      };

      # ---- Classification + handle re-wrap ------------------------------
      #
      # The raw pipeline resolves step references to derivations and
      # stamps meta.pointy = { id, args }; args are re-wrapped to sibling
      # handles through the same contract parameter kinds the raw
      # pipeline resolves with (subject/subjects/listSubject).  Declared
      # contract parameters of those kinds participate as references;
      # record fields stay ordinary values.
      handleOfStep = value:
        handles.${builtins.toString value.meta.pointy.id} or (throw "pointy.semantic: resolved step reference is missing meta.pointy.id");
      wrapHandles = kind: value:
        if kind == "subject" || kind == "listSubject" then
          handleOfStep value
        else if kind == "subjects" then
          builtins.map handleOfStep value
        else
          value;

      # ---- Per-record handles --------------------------------------------
      #
      # A record whose raw step the stdlib rejects (missing/invalid args)
      # has no raw resolution to consume and no semantic application; it
      # surfaces as a marked placeholder.  Lazy and acyclic because record
      # dependency graphs are DAGs.
      handleResult = id: rec_:
        let
          meta = metas.${rec_.type};
          rawStep = steps.${id};
          resolvedEv = builtins.tryEval rawStep.drvPath;
        in
        if !resolvedEv.success then {
          __unresolvable = true;
          inherit id;
          type = rec_.type;
          reason = "the raw pipeline rejects this record before semantic resolution (missing/invalid required args); see .#pointy.steps.\"${id}\"";
        }
        else
          let
            resolvedHandles = builtins.mapAttrs (argName: value:
              if meta.paramKinds ? ${argName} then
                wrapHandles meta.paramKinds.${argName} value
              else
                value
            ) rawStep.meta.pointy.args;
            # Effective call arguments, canonical and param-keyed:
            # authored defaults under the record's resolved values
            # (record wins; resolvedHandles already carries the raw step's
            # param-keyed canonical args), plus the record id.  The
            # projection reads contract parameters out of this same
            # union, so semantics and the raw builder consume identical
            # effective arguments.  A defaulted empty reference list
            # becomes the canonical empty { subjects = [ ]; } envelope
            # under the subject param's name: the checker rejects a bare
            # [] for a subjects-kind parameter.
            callArgs = builtins.mapAttrs (argName: value:
              if
                meta.paramKinds ? ${argName}
                && meta.paramKinds.${argName} == "subjects"
                && value == [ ]
              then
                { subjects = [ ]; }
              else
                value
            ) (meta.defaults // resolvedHandles // { inherit id; });
            contract = templates.${rec_.type}.contract;
          in
          (langLib.mkSidecar {
            source = entrySource;
            modules = entryModules;
            interface = contract.interface;
            output = contract.output;
            arguments = projectionOf contract;
            construct = _args: rawStep;
            scanners = scannerBundles;
            key = id;
          }) callArgs;

      handles = builtins.mapAttrs handleResult records;

      unresolvable = builtins.attrNames (
        lib.filterAttrs (_: h: h.__unresolvable or false) handles
      );

      resolvableMap = pick:
        builtins.foldl' (acc: id:
          let h = handles.${id}; in
          if h.__unresolvable or false then acc else acc // { "${id}" = pick h; }
        ) { } (builtins.attrNames handles);

      transport = {
        applications = langLib.pointyApplicationsDoc {
          name = "pointy-applications.json";
          apps = resolvableMap (h: h.pointyInternals.entry);
        };
        modules = builtins.toFile "pointy-modules.json"
          (builtins.toJSON sel.modules);
        entryTree = entryTree;
      };

      # ---- Presenter metadata --------------------------------------------
      #
      # Per-template parameter specs from the declared
      # contract.parameters partition plus the binding table.  The table
      # is the host side of the merge the conformance check validates
      # against the core; evaluation never reads MODEL bytes.
      # ---- Host documents (build inputs) -------------------------------
      #
      # The host's core argument schema: generated by the core over the
      # host's OWN enrolled sources (`pointy check --schema`), a
      # derivation output.  The stepConfig derivation (default module)
      # and the host conformance check consume it, and evaluation reads
      # it through the user-authorized IFD for construction defaults.
      # `adapter` is the host's plain-data presentation
      # table (contract metadata + optional bindings + builderArgs) the
      # merge validates against the schema with unknown override names
      # rejected.
      contractSchema = pointyLib.mkContractSchema {
        inherit pkgs;
        pointy = sel.language.packages.${system}.pointy;
        entryTree = entryTree;
        modules = sel.modules;
      };

      adapter = pointyLib.hostAdapter templates;

      checked = resolvableMap (h: h.target);
      certificates = resolvableMap (h: h.certificate);
    in
    {
      # Computed kernel, merged into flake.pointy by the default module
      # (flake outputs accept one definer per attribute).
      pointy.semantic.result = {
        inherit handles unresolvable transport;
        inherit checked certificates adapter;
        inherit contractSchema;
        contractModel = sharedModel;
      };
    }
  );
}
