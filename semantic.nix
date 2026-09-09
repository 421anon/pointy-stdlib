# Host configuration is in the README.
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
      default = {
        csv = "ext/csv.pointy";
      };
      description = "Logical module name -> source-relative path the entry program imports it at. The csv observation module is pre-enrolled by default; hosts extend or override per key.";
    };
    scanners = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {
        csv = { };
      };
      description = "Observation-interface name -> optional bundle overrides ({ interface; program }) over the language flake's pointyScanners.<system>.<name>. The csv bundle is pre-enrolled with its stdlib interface variant by default; hosts extend or override per key.";
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
      # mkFlake fixes the system list.
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

      projectionOf = params: args:
        builtins.listToAttrs (builtins.map (p: {
          name = p.param;
          value = args.${p.param};
        }) params);

      templates = top.config.pointy.templates;
      records = top.config.pointy.stepDefs;
      modulesFile = builtins.toFile "pointy-modules.json" (builtins.toJSON sel.modules);
      contractSchema = langLib.mkArgumentSchema {
        source = entrySource;
        modules = entryModules;
      };
      coreSchema = builtins.fromJSON (builtins.readFile (builtins.toString contractSchema));
      metas = pointyLib.templateMeta { inherit templates; schema = coreSchema; };

      # The same eval the default module publishes as packages.pointy.steps.
      steps = pointyLib.evalSteps (top.config.pointy // { inherit pkgs metas; });

      # ---- Semantic sources --------------------------------------------
      #
      # entryTree assembles the source-relative layout the entry
      # program's imports rely on.  Copied, not symlinked: the core's
      # containment audit rejects symlink escapes.
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

      # The certifier coverage gate requires the interface path as a
      # direct inputSrc.
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
          reason = "the raw pipeline rejects this record before semantic resolution (missing/invalid args, an unresolvable producer dependency, or a template assertion); see .#pointy.steps.\"${id}\"";
        }
        else
          let
            resolvedHandles = builtins.mapAttrs (argName: value:
              if meta.paramKinds ? ${argName} then
                wrapHandles meta.paramKinds.${argName} value
              else
                value
            ) rawStep.meta.pointy.args;
            contract = templates.${rec_.type}.contract;
            callArgs = meta.defaults // resolvedHandles // { inherit id; };
          in
          (langLib.mkSidecar {
            source = entrySource;
            modules = entryModules;
            interface = contract.interface;
            output = meta.output;
            arguments = projectionOf meta.params;
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
        modules = modulesFile;
        entryTree = entryTree;
      };

      # ---- Presenter metadata --------------------------------------------
      checked = resolvableMap (h: h.target);
      certificates = resolvableMap (h: h.certificate);
    in
    {
      # Merged into flake.pointy by the default module.
      pointy.semantic.result = {
        inherit unresolvable transport;
        inherit checked certificates;
        inherit contractSchema;
        contractModel = sharedModel;
      };
    }
  );
}
