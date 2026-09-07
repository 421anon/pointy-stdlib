# Semantic host adapter: one pointy-language contract layer over the raw
# steps.  Activated by `pointy.semantic.enable = true` in a host repo's
# pointy config; the stdlib itself stays language-agnostic — the host
# declares the pointy-language flake input name to use.
#
# The host supplies only:
#   semantic.source       the entry program (conventionally main.pointy)
#   semantic.modules      logical module name -> source-relative path the
#                         entry program imports (e.g. csv = "ext/csv.pointy")
#   semantic.scanners     observation-interface name -> bundle override ({}
#                         takes <language-input>.pointyScanners.<system>.<name>)
#
# Templates carry the contract convention:
#   contract = { interface; output; parameters = [ { param; option; } ... ]; }
# i.e. the semantic parameter partition is authored once per template, in
# projection order; the adapter derives the projections, the presenter
# specs, and the transport documents from it.
{ pointyLib }:
top:
let
  lib = top.lib;
  sel = top.config.pointy.semantic;
in
{
  options.pointy.semantic = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Derive per-step semantic handles, presenter metadata, and transport documents over the raw steps.";
    };
    language-input = lib.mkOption {
      type = lib.types.str;
      default = "pointy-lang";
      description = "Flake input name of the pointy language (semantic core + scanner bundles).";
    };
    source = lib.mkOption {
      type = lib.types.raw;
      description = "Entry program source (conventionally main.pointy). Required when enable = true.";
    };
    modules = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Logical module name -> source-relative path the entry program imports it at.";
    };
    scanners = lib.mkOption {
      type = lib.types.attrsOf lib.types.attrs;
      default = { };
      description = "Observation-interface name -> optional bundle overrides ({ interface; program }) over <language-input>.pointyScanners.<system>.<name>.";
    };
  };

  config = lib.mkIf sel.enable {
    # Top-level domain surface mirrored from the per-system kernel (the
    # kernel needs pkgs; the flake-level attrs reach it through self, and
    # the dependency is acyclic — only the host-authored semantic options
    # feed the kernel).
    flake.pointy = {
      handles = top.inputs.self.packages.x86_64-linux.pointy.semantic.handles;
      unresolvable = top.inputs.self.packages.x86_64-linux.pointy.semantic.unresolvable;
      notebookAdapter = top.inputs.self.packages.x86_64-linux.pointy.semantic.notebookAdapter;
      transport = top.inputs.self.packages.x86_64-linux.pointy.semantic.transport;
    };

    perSystem =
      { pkgs, system, ... }:
      let
        langFlake = top.inputs.${sel.language-input};
        langLib = langFlake.lib.${system};

        resolveBundle = name: spec:
          let
            bundle = langFlake.pointyScanners.${system}.${name} or
              throw "pointy.semantic: no scanner bundle `${name}' in ${sel.language-input}.pointyScanners.${system}";
          in
          {
            interface = spec.interface or bundle.interface;
            program = spec.program or bundle.program;
          };

        resolvedScanners = builtins.mapAttrs resolveBundle sel.scanners;

        # Structural projection composed from a template's declared
        # contract.parameters: param -> the application parameter name,
        # option -> the resolved builder option it reads.  The list is the
        # projection order.
        projectionOf = contract: args:
          builtins.listToAttrs (builtins.map (pair: {
            name = pair.param;
            value = builtins.getAttr pair.option args;
          }) contract.parameters);

        templates = top.config.pointy.templates;
        records = top.config.pointy.stepDefs;
        # Same evaluation the default module publishes as packages.pointy.steps
        # (identical derivations — same function, args, pkgs).  Evaluated
        # here rather than read back from config: reading
        # config.packages.pointy while defining packages.pointy.* merges
        # the node into itself (infinite recursion).
        steps = pointyLib.evalSteps (top.config.pointy // { inherit pkgs; });

        compiledTemplates = builtins.mapAttrs (
          _: tpl:
          tpl.compile {
            lib = top.inputs.nixpkgs/lib;
            inherit pkgs pointyLib;
          }
        ) templates;

        # ---- Semantic sources ------------------------------------------
        #
        # entryTree assembles the minimal source-relative layout the entry
        # program's imports rely on: main.pointy at the root plus every
        # enrolled module copied to its declared relative path, sourced
        # from its scanner bundle interface (no vendored copies in host
        # repos).  Copied, not symlinked: the core's containment audit
        # rejects symlink escapes, and only these files feed the model
        # chain.
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

        # ---- Classification + handle re-wrap ----------------------------
        #
        # The raw pipeline resolves step references to derivations and
        # stamps meta.pointy = { id, args }; args are re-wrapped to
        # sibling handles via the same compiled-option classification the
        # raw pipeline resolves with.
        handleOfStep = value:
          handles.${builtins.toString value.meta.pointy.id}
            or (throw "pointy.semantic: resolved step option value is missing meta.pointy.id");
        wrapHandles = name: opts: value:
          let
            argTypes = opts.${name}.type.description.type or { };
          in
          if argTypes ? step then handleOfStep value
          else if argTypes ? list && argTypes.list ? step then
            builtins.map handleOfStep value
          else value;

        # ---- Per-record handles ------------------------------------------
        #
        # A record whose raw step the stdlib rejects (missing/invalid args)
        # has no raw resolution to consume and no semantic application; it
        # surfaces as a marked placeholder.  Lazy and acyclic because
        # record dependency graphs are DAGs.
        handleResult = id: rec_:
          let
            opts = compiledTemplates.${rec_.type}.options;
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
              resolvedHandles = builtins.mapAttrs (name: wrapHandles name opts)
                rawStep.meta.pointy.args;
              callArgs = builtins.mapAttrs (name: opt:
                if builtins.hasAttr name resolvedHandles then resolvedHandles.${name}
                else opt.default) (builtins.removeAttrs opts [ "id" ])
                // { inherit id; };
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

        # ---- Presenter metadata ------------------------------------------
        #
        # Per-template parameter specs from the declared
        # contract.parameters partition plus the compiled option schemas;
        # never reads MODEL bytes.
        paramSpecFor = name:
          let
            params = templates.${name}.contract.parameters
              or (throw "pointy.template `${name}': contract.parameters missing");
            paramNames = builtins.map (p: p.param) params;
            dupes = builtins.filter (n:
              builtins.length (builtins.filter (x: x == n) paramNames) > 1)
              (lib.unique paramNames);
          in
          builtins.seq
            (if dupes != [ ] then
              throw ("pointy.template `${name}': duplicate contract.parameters name(s): "
                + builtins.concatStringsSep ", " dupes)
            else null) params;

        templateAdapter = name: tpl:
          let
            opts = compiledTemplates.${name}.options;
            pairs = paramSpecFor name;
            params = builtins.listToAttrs (
              lib.imap0 (i: pair:
                let
                  opt = opts.${pair.option}
                    or (throw "pointy.template `${name}': contract.parameters references unknown option `${pair.option}'");
                  d = opt.type.description or { };
                in
                {
                  name = pair.param;
                  value = {
                    order = i;
                    displayName = d.displayName or null;
                    description = d.description or null;
                    type = d.type or null;
                    default = opt.default or null;
                  };
                }
              ) pairs
            );
          in
          {
            interface = tpl.contract.interface;
            displayName = tpl.displayName or null;
            icon = tpl.icon or null;
            sortKey = tpl.sortKey or null;
            description = tpl.description or null;
            parameters = params;
          };

        semantic = {
          inherit handles unresolvable transport;
          notebookAdapter = builtins.toJSON (builtins.mapAttrs templateAdapter templates);
        };
      in
      {
        packages.pointy = {
          checked = resolvableMap (h: h.target);
          certificates = resolvableMap (h: h.certificate);
          contractModel = sharedModel;
          semantic = semantic;
        };
      };
  };
}
