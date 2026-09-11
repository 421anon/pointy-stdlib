{ pointyLib, pointy-lang }:
top:
let
  lib = top.lib;
  sel = top.config.pointy.semantic;
  cfg = top.config.pointy;
in
{
  options.pointy.semantic = {
    language = lib.mkOption {
      type = lib.types.raw;
      default = pointy-lang;
      description = "The pointy language flake (compiler and scanner bundles).";
    };
    pkgs = lib.mkOption {
      type = lib.types.raw;
      description = "The one pkgs for raw steps, entry sources, and certificates.";
    };
    source = lib.mkOption {
      type = lib.types.raw;
      description = "Entry program source (conventionally main.pointy).";
    };
    modules = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {
        csv = "ext/csv.pointy";
      };
      description = "Logical module name -> source-relative import path; csv is pre-enrolled.";
    };
    scanners = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = {
        csv = { };
      };
      description = "Observation-interface name -> { interface; program } overrides; csv is pre-enrolled.";
    };
    result = lib.mkOption {
      internal = true;
      type = lib.types.attrs;
      default = { };
      description = "Semantic kernel: contract tables, raw steps, and per-record results.";
    };
  };

  config.pointy.semantic = (
    let
      # mkFlake fixes the system list.
      system = "x86_64-linux";
      pkgs = sel.pkgs;
      langLib = sel.language.lib.${system};

      scanners = builtins.mapAttrs (
        name: spec:
        let
          bundle = sel.language.pointyScanners.${system}.${name}
            or (throw "pointy.semantic: no scanner bundle `${name}' in pointyScanners.${system}");
        in
        {
          interface = spec.interface or bundle.interface;
          program = spec.program or bundle.program;
        }
      ) sel.scanners;

      templates = cfg.templates;
      records = cfg.stepDefs;
      modulesFile = builtins.toFile "pointy-modules.json" (builtins.toJSON sel.modules);
      contractSchema = langLib.mkArgumentSchema {
        source = entrySource;
        modules = entryModules;
      };
      coreSchema = builtins.fromJSON (builtins.readFile (builtins.toString contractSchema));
      metas = pointyLib.templateMeta { inherit templates; schema = coreSchema; };
      steps = pointyLib.evalSteps (cfg // { inherit pkgs metas; });

      # The source-relative layout the entry program's imports rely on.
      # Copied, not symlinked: the core's containment audit rejects escapes.
      moduleSources = builtins.mapAttrs (name: rel: {
        inherit rel;
        src = scanners.${name}.interface
          or (throw "pointy.semantic: module `${name}' has no same-named scanner bundle");
      }) sel.modules;
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

      # The certifier coverage gate wants each interface as a direct inputSrc.
      scannerBundles = builtins.mapAttrs (_: b: {
        interface = builtins.path {
          path = b.interface;
          name = "pointy-scanner-interface";
        };
        program = b.program;
      }) scanners;

      # Producer handle lookup; a rejected producer names both ends.
      handleOf =
        consumerId: ref:
        let
          producerId = builtins.toString ref.meta.pointy.id;
        in
        handles.${producerId}
          or (throw "pointy.semantic: step `${consumerId}' references unresolvable step `${producerId}'");

      handleResult =
        id: rec_:
        let
          meta = metas.${rec_.type};
          rawStep = steps.${id};
        in
        if (builtins.tryEval rawStep.drvPath).success then
          (langLib.mkSidecar {
            source = entrySource;
            modules = entryModules;
            interface = meta.interface;
            output = meta.output;
            arguments = builtins.intersectAttrs meta.paramKinds;
            construct = _: rawStep;
            scanners = scannerBundles;
            key = id;
          }) (meta.defaults
            // builtins.mapAttrs (
              argName: value:
              if meta.paramKinds ? ${argName} then
                pointyLib.mapSubjectRefs (handleOf id) meta.paramKinds.${argName} value
              else
                value
            ) rawStep.meta.pointy.args
            // { inherit id; })
        else
          {
            __unresolvable = true;
          };

      all = builtins.mapAttrs handleResult records;
      rejected = lib.filterAttrs (_: h: h.__unresolvable or false) all;
      handles = builtins.removeAttrs all (builtins.attrNames rejected);
    in
    {
      result = {
        inherit contractSchema metas steps;
        contractModel = langLib.mkContractModel {
          source = entrySource;
          modules = entryModules;
        };
        unresolvable = builtins.attrNames rejected;
        checked = builtins.mapAttrs (_: h: h.target) handles;
        certificates = builtins.mapAttrs (_: h: h.certificate) handles;
        transport = {
          applications = langLib.pointyApplicationsDoc {
            name = "pointy-applications.json";
            apps = builtins.mapAttrs (_: h: h.pointyInternals.entry) handles;
          };
          modules = modulesFile;
          entryTree = entryTree;
        };
      };
    }
  );
}
