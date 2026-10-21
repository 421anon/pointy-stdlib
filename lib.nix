{
  self,
  nixpkgs,
  flake-parts,
  ...
}:
rec {
  renderStepConfig = (import ./lib/step-config.nix { inherit (nixpkgs) lib; }).renderStepConfig;

  api = {
    inherit
      mkFlake
      loadDir
      csvExtras
      fastqExtras
      nixDepPkgs
      stepLinkCommands
      ;
  };

  copyPaths =
    { src, paths }:
    let
      ancestors =
        path:
        let
          parts = nixpkgs.lib.splitString "/" path;
        in
        nixpkgs.lib.genList (i: nixpkgs.lib.concatStringsSep "/" (nixpkgs.lib.take (i + 1) parts)) (
          builtins.length parts
        );
      included = builtins.concatMap ancestors paths;
      relative =
        path: nixpkgs.lib.removePrefix (toString src + "/") (toString path);
    in
    builtins.path {
      path = src;
      name = "pointy-src";
      filter =
        path: _:
          path == src
          || builtins.elem (relative path) included
          || builtins.any (p: nixpkgs.lib.hasPrefix (p + "/") (relative path)) included;
    };

  nixDepPkgs =
    { pkgs, nixDeps }:
    map (
      name:
      let
        path = nixpkgs.lib.splitString "." name;
      in
      assert nixpkgs.lib.assertMsg (nixpkgs.lib.hasAttrByPath path pkgs) "Unknown Nix package `${name}`.";
      nixpkgs.lib.getAttrFromPath path pkgs
    ) nixDeps;

  stepLinkCommands =
    { stepDeps }:
    builtins.concatStringsSep "\n" (map (depPkg: "ln -s ${depPkg} ./${depPkg.meta.pointy.id}") stepDeps);

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

  arityOf =
    shape:
    {
      subject = "one";
      array = { subject = "many"; }.${shape.element.kind or "data"} or null;
    }
    .${shape.kind or "data"} or null;

  templateMeta =
    { templates, interfaces }:
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
          assert
            !(sp ? error)
            || throw "pointy.template `${name}': the core schema reports `${sp.error}' for interface `${interface}' parameter `${sp.parameter or "?"}'";
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
        subjectParams = builtins.filter (p: p.arity != null) params;
      in
      {
        inherit interface params subjectParams;
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

  subjectRefs =
    args: p:
    if p.arity == "one" then
      nixpkgs.lib.optionals (args ? ${p.param}) [ (stepIdFromRef args.${p.param}) ]
    else
      builtins.map stepIdFromRef (nixpkgs.lib.toList (args.${p.param} or [ ]));

  applicationOf =
    { stepDefs, metas }:
    id:
    let
      def = stepDefs.${id} or (throw "pointy.step ${id}: the step is not defined");
      meta =
        metas.${def.type}
          or (throw "pointy.step ${id}: no template declares the type `${def.type}'");
      refs = subjectRefs (def.args or (throw "pointy.step ${id}: the definition has no args"));
      argument =
        p:
        if p.arity == null then
          nixpkgs.lib.optionalAttrs (
            def.args ? ${p.param} && (p.default == null || def.args.${p.param} != p.default)
          ) { ${p.param} = def.args.${p.param}; }
        else if p.arity == "one" then
          nixpkgs.lib.optionalAttrs (refs p != [ ]) {
            ${p.param} = { subject = builtins.head (refs p); };
          }
        else
          { ${p.param} = if refs p == [ ] then [ ] else { subjects = refs p; }; };
      edges =
        p:
        nixpkgs.lib.imap0 (i: subject: {
          parameterPath = if p.arity == "one" then [ p.param ] else [ p.param i ];
          inherit subject;
        }) (refs p);
    in
    {
      interface = meta.interface;
      arguments = builtins.foldl' (acc: p: acc // argument p) { } meta.params;
      subjectEdges = builtins.concatMap edges meta.subjectParams;
      refinements = [ ];
    }
    // nixpkgs.lib.optionalAttrs ((def.refine or null) != null) { inherit (def) refine; };

  rekeyApplication =
    keys: application:
    let
      rekey = subject: keys.${subject} or subject;
      argument =
        value:
        if value ? subject then
          value // { subject = rekey value.subject; }
        else if value ? subjects then
          value // { subjects = builtins.map rekey value.subjects; }
        else
          value;
    in
    application
    // {
      arguments = builtins.mapAttrs (_: argument) application.arguments;
      subjectEdges = builtins.map (
        edge: edge // { subject = rekey edge.subject; }
      ) application.subjectEdges;
    };

  evalApplications =
    { stepDefs,
      metas,
      ...
    }:
    builtins.mapAttrs (id: _: applicationOf { inherit stepDefs metas; } id) stepDefs;

  evalSubjectBindings =
    { stepDefs, metas, steps, ... }:
    id:
    let
      def = stepDefs.${id} or (throw "pointy.step ${id}: the step is not defined");
      meta =
        metas.${def.type}
          or (throw "pointy.step ${id}: no template declares the type `${def.type}'");
      refs = subjectRefs (def.args or (throw "pointy.step ${id}: the definition has no args"));
      pathsOf =
        p:
        builtins.map (
          ref:
          steps.${ref}.outPath
            or (throw "pointy.step ${id}: the producer `${ref}' is not defined")
        ) (refs p);
      binding =
        p:
        if p.arity == "one" then
          nixpkgs.lib.optionalAttrs (refs p != [ ]) { ${p.param} = builtins.head (pathsOf p); }
        else
          { ${p.param} = pathsOf p; };
    in
    builtins.foldl' (acc: p: acc // binding p) { } meta.subjectParams;

  evalSteps =
    {
      stepDefs,
      templates,
      pkgs,
      srcDirOf,
      metas,
      ...
    }:
    let
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
      extrasFor = {
        csv = csvExtras;
        fastq = fastqExtras;
      };
      steps =
        stepDefs
        |> builtins.mapAttrs (
          id: def:
          let
            type = def.type or (throw "pointy.step ${id}: the definition has no type");
            args = def.args or (throw "pointy.step ${id}: the definition has no args");
            requirements = def.requirements or null;
            meta =
              metas.${type}
                or (throw "pointy.step ${id}: no template declares the type `${type}'");
            template =
              templates.${type}
                or (throw "pointy.step ${id}: the repository has no template `${type}'");
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
              // builtins.listToAttrs (
                builtins.map (p: {
                  name = p.param;
                  value =
                    mapSubjectRefs (
                      ref:
                      steps.${stepIdFromRef ref}
                        or (throw "pointy.step ${id}: the producer `${stepIdFromRef ref}' is not defined")
                    ) p.arity;
                }) meta.subjectParams
              );

            resolve = builtins.mapAttrs (argName: value: (argRefs.${argName} or (v: v)) value) args;

            src = srcDirOf id;
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
            declaredRequirements = template.requirements or { };
            resolvedRequirements =
              if requirements != null then
                requirements
              else
                let
                  declared =
                    if builtins.isFunction declaredRequirements then
                      declaredRequirements resolvedArgs
                    else
                      declaredRequirements;
                in
                defaultRequirements // declared;
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
              if src.hasSrcDir then
                {
                  unpackPhase = "find ${src.srcDir} -mindepth 1 -maxdepth 1 -print0 | xargs -0 -r -I{} ln -s {} .";
                }
              else
                {
                  dontUnpack = true;
                };
            cfg = compiledTemplates.${type}.build {
              args = normalizedArgs;
              public = result;
            };
            stepName = cfg.name or type;
            stepVersion = cfg.version or "1";
            extras = nixpkgs.lib.optionalAttrs (template ? extras) {
              extras =
                (extrasFor.${template.extras}
                  or (throw "pointy.${type}: unknown extras kind `${template.extras}`"))
                  {
                    inherit pkgs;
                    baseDrv = result;
                  };
            };
            result = pkgs.stdenv.mkDerivation (
              {
                pname = stepName;
                version = stepVersion;
                trotterPackage = "true";
              }
              // (cfg.env or { })
              // (cfg.mkDerivation or { })
              // sourceOverride
            );
          in
          result
          // {
            name = stepName;
            version = stepVersion;
            requirements = resolvedRequirements;
            meta = (result.meta or { }) // {
              pointy = (result.meta.pointy or { }) // {
                inherit id type;
                requirements = resolvedRequirements;
                args = resolvedArgs;
              } // extras;
            };
          }
        );
    in
    steps;

  evalAutocomplete =
    { templates, pkgs }:
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
    { templates, presets }:
    builtins.mapAttrs (
      name: preset:
      let
        unknown = builtins.filter (t: !(templates ? ${t})) preset.templates;
      in
      if unknown != [ ] then
        throw "Preset `${name}` references unknown templates: ${nixpkgs.lib.concatStringsSep ", " unknown}."
      else
        preset
        // {
          description = preset.description or null;
          sortKey = preset.sortKey or null;
        }
    ) presets;

  evalProjects =
    {
      projects,
      templates,
      presets ? { },
      stepDefs,
    }:
    builtins.mapAttrs (
      id: proj:
      let
        preset = proj.preset or null;
        declaredTemplates = proj.templates or null;
        hasPreset = preset != null;
        hasTemplates = declaredTemplates != null;
        unknownTemplates =
          if hasTemplates then builtins.filter (t: !(templates ? ${t})) declaredTemplates else [ ];
        isStep = child: child ? step;
        stepIdOf = child: toString child.step.id;
        projectIdOf = child: toString child.project.id;
        isKnown =
          child:
          if isStep child then stepDefs ? ${stepIdOf child} else projects ? ${projectIdOf child};
        unknownChildren = builtins.filter (child: !(isKnown child)) proj.children;
        unknownStepIds = map stepIdOf (builtins.filter isStep unknownChildren);
        unknownProjectIds = map projectIdOf (
          builtins.filter (child: !(isStep child)) unknownChildren
        );
        validationErrors =
          nixpkgs.lib.optional (
            hasPreset && !(presets ? ${preset})
          ) "Unknown preset `${preset}`. Pick another preset in the edit form."
          ++
            nixpkgs.lib.optional (hasTemplates && unknownTemplates != [ ])
              "Unknown templates: ${nixpkgs.lib.concatStringsSep ", " unknownTemplates}. Remove them in the edit form."
          ++ nixpkgs.lib.optional (
            unknownStepIds != [ ]
          ) "Unknown step ids: ${nixpkgs.lib.concatStringsSep ", " unknownStepIds}."
          ++ nixpkgs.lib.optional (
            unknownProjectIds != [ ]
          ) "Unknown project ids: ${nixpkgs.lib.concatStringsSep ", " unknownProjectIds}.";
      in
      if !hasPreset && !hasTemplates then
        throw "Project `${id}` must define either `preset` or `templates`."
      else if hasPreset && hasTemplates then
        throw "Project `${id}` cannot define both `preset` and `templates`."
      else
        proj
        // {
          inherit preset;
          templates = declaredTemplates;
          id = nixpkgs.lib.toIntBase10 id;
          children = map (
            child:
            if isStep child then
              { step = child.step // { def = stepDefs.${stepIdOf child}; }; }
            else
              child
          ) (builtins.filter isKnown proj.children);
          inherit validationErrors;
        }
    ) projects;

  evalProjectFolders =
    { projects }:
    let
      projectsById = builtins.listToAttrs (
        builtins.map (
          key:
          {
            name = builtins.toString projects.${key}.id;
            value = projects.${key};
          }
        ) (builtins.attrNames projects)
      );

      innerOf = child: if child ? step then child.step else child.project;
      isStepChild = child: child ? step;
      refKey = child: (if isStepChild child then "s" else "p") + builtins.toString (innerOf child).id;

      placement =
        child:
        let
          inner = innerOf child;
          sortKey = inner.sortKey or null;
        in
        if builtins.isInt sortKey then
          {
            rank = 0;
            key = sortKey;
            id = inner.id;
          }
        else
          {
            rank = 1;
            key = 0;
            id = inner.id;
          };

      entryLess =
        a: b:
        let
          first = placement a;
          second = placement b;
        in
        first.rank < second.rank
        || (
          first.rank == second.rank
          && (first.key < second.key || (first.key == second.key && first.id < second.id))
        );

      effectiveChildren =
        pid:
        if !(projectsById ? ${pid}) then
          [ ]
        else
          let
            deduped = builtins.foldl' (
              acc: child:
              let key = refKey child; in
              if acc.seen ? ${key} then
                acc
              else
                {
                  seen = acc.seen // { ${key} = true; };
                  out = acc.out ++ [ child ];
                }
            ) { seen = { }; out = [ ]; } (projectsById.${pid}.children or [ ]);
          in
          builtins.sort entryLess deduped.out;

      childFolder =
        pid: childId:
        let
          matches = builtins.filter (
            child:
            !(isStepChild child)
            && builtins.toString (innerOf child).id == builtins.toString childId
          ) (effectiveChildren pid);
        in
        if matches == [ ] then null else builtins.toString (innerOf (builtins.head matches)).id;

      folderAt =
        path:
        builtins.foldl' (
          current: childId:
          if current == null then null else childFolder current childId
        ) (if projectsById ? "0" then "0" else null) path;

      holdsStep =
        path: stepId:
        let pid = folderAt path; in
        pid != null
        && builtins.any (
          child: isStepChild child && builtins.toString (innerOf child).id == builtins.toString stepId
        ) (effectiveChildren pid);

      roots =
        let
          ids = builtins.attrNames projectsById;
          nestedIds = builtins.foldl' (
            acc: pid:
            builtins.foldl' (
              acc2: child:
              if isStepChild child then acc2 else acc2 // { ${builtins.toString (innerOf child).id} = true; }
            ) acc (effectiveChildren pid)
          ) { } ids;
        in
        builtins.sort (
          a: b: projectsById.${a}.id < projectsById.${b}.id
        ) (builtins.filter (pid: !(nestedIds ? ${pid})) ids);

      walk =
        visited: ancestors: pid:
        let
          projectId = projectsById.${pid}.id;
          path = if projectId == 0 then [ ] else ancestors ++ [ projectId ];
          children = effectiveChildren pid;
          here = builtins.map (child: {
            step = builtins.toString (innerOf child).id;
            inherit path;
          }) (builtins.filter isStepChild children);
          visitedHere = visited // { ${pid} = true; };
          nested = builtins.concatMap (
            child:
            if isStepChild child then
              [ ]
            else
              let childPid = builtins.toString (innerOf child).id; in
              if visitedHere ? ${childPid} then [ ] else walk visitedHere path childPid
          ) children;
        in
        here ++ nested;

      stepPaths = builtins.foldl' (
        acc: entry:
        if acc ? ${entry.step} then
          acc
        else
          acc // { ${entry.step} = entry.path; }
      ) { } (builtins.concatMap (walk { } [ ]) roots);

      stepPath = stepId: stepPaths.${builtins.toString stepId} or [ ];

      folderLabel =
        path:
        if path == [ ] then
          "the root folder"
        else if !(builtins.isList path) || !(builtins.all builtins.isInt path) then
          "the recorded folder"
        else
          builtins.concatStringsSep " › " (
            builtins.map (
              projectId:
              let project = projectsById.${builtins.toString projectId} or null; in
              if project == null then builtins.toString projectId else project.name or (builtins.toString projectId)
            ) path
          );
    in
    {
      inherit
        effectiveChildren
        folderAt
        holdsStep
        roots
        stepPath
        folderLabel
        ;
      projectId = pid: projectsById.${pid}.id;
      pathIsValid = path: builtins.isList path && builtins.all builtins.isInt path;
    };

  evalLinkedData =
    {
      stepDefs,
      templates,
      metas,
      folders,
      rev,
      steps,
    }:
    let
      stepIds = builtins.attrNames stepDefs;
      defOf = id: stepDefs.${id};
      metaOf = id: metas.${(defOf id).type or ""} or { subjectParams = [ ]; };
      kindOf = id: (templates.${(defOf id).type or ""} or { }).pointy.type or { };
      isDerivation = id: kindOf id ? derivation;
      stepIdOf = id: (defOf id).id or (nixpkgs.lib.toIntBase10 id);

      referenceValues =
        args: p:
        if p.arity == "one" then
          nixpkgs.lib.optionals (args ? ${p.param}) [ args.${p.param} ]
        else
          nixpkgs.lib.toList (args.${p.param} or [ ]);

      referencesOf =
        id:
        let
          args = (defOf id).args or { };
        in
        builtins.concatMap (
          p: builtins.map (value: { field = p.param; inherit value; }) (referenceValues args p)
        ) (metaOf id).subjectParams;

      directReferencesOf = id: if isDerivation id then referencesOf id else [ ];

      referenceStep = reference: builtins.toString reference.value.step;
      referenceHasPath = reference: reference.value ? path;
      referencePath = reference: reference.value.path;

      isStale =
        reference:
        if !(referenceHasPath reference) then
          false
        else if !(folders.pathIsValid (referencePath reference)) then
          true
        else
          !(folders.holdsStep (referencePath reference) (referenceStep reference));

      staleOf =
        id:
        builtins.map (reference: {
          step = stepIdOf id;
          inherit reference;
        }) (builtins.filter isStale (referencesOf id));

      staleDependencies = builtins.sort (a: b: a.step < b.step) (
        builtins.map (entry: {
          inherit (entry) step;
          dependency = entry.reference.value;
        }) (builtins.concatMap staleOf stepIds)
      );

      noticesOf =
        id:
        builtins.map (
          reference:
          let dependency = builtins.toString reference.value.step; in
          {
            inherit (reference) field;
            severity = "info";
            message = "Step ${dependency} is not in folder ${folders.folderLabel (referencePath reference)} at this commit; the reference falls back to step ${dependency} wherever it lives.";
          }
        ) (builtins.filter isStale (referencesOf id));

      resolveReference =
        reference:
        let
          step = referenceStep reference;
          recorded = referencePath reference;
          keepRecorded =
            referenceHasPath reference
            && folders.pathIsValid recorded
            && folders.holdsStep recorded step;
        in
        {
          inherit step;
          path = if keepRecorded then recorded else folders.stepPath step;
        };

      nodeKey =
        node: builtins.concatStringsSep "/" (builtins.map builtins.toString node.path) + "/" + node.step;

      childrenOfNode =
        node:
        builtins.map resolveReference (
          builtins.filter (reference: stepDefs ? ${referenceStep reference}) (directReferencesOf node.step)
        );

      collect =
        start:
        let
          go =
            queue: seen: acc:
            if queue == [ ] then
              acc
            else
              let
                node = builtins.head queue;
                key = nodeKey node;
                rest = builtins.tail queue;
              in
              if seen ? ${key} then
                go rest seen acc
              else
                go (rest ++ childrenOfNode node) (seen // { ${key} = true; }) (acc ++ [ node ]);
        in
        go [ start ] { } [ ];

      pathLess =
        left: right:
        if left == [ ] then
          right != [ ]
        else if right == [ ] then
          false
        else
          builtins.head left < builtins.head right
          || (builtins.head left == builtins.head right && pathLess (builtins.tail left) (builtins.tail right));

      nodeLess =
        left: right:
        stepIdOf left.step < stepIdOf right.step
        || (stepIdOf left.step == stepIdOf right.step && pathLess left.path right.path);

      revision =
        if rev == null then throw "pointy: linked data needs a committed revision" else builtins.toString rev;

      iriOf =
        node:
        "/artifact/"
        + builtins.concatStringsSep "/" (builtins.map builtins.toString (node.path ++ [ node.step ]))
        + "/"
        + revision;

      hexDigits = [
        "0"
        "1"
        "2"
        "3"
        "4"
        "5"
        "6"
        "7"
        "8"
        "9"
        "a"
        "b"
        "c"
        "d"
        "e"
        "f"
      ];
      hexPair =
        code:
        builtins.elemAt hexDigits (code / 16) + builtins.elemAt hexDigits (code - 16 * (code / 16));
      unicodeChar = code: builtins.fromJSON ("\"\\u00" + hexPair code + "\"");
      unicodeEscape = code: builtins.fromJSON ("\"\\\\u00" + hexPair code + "\"");
      controlCodes = builtins.filter (code: code != 0) (builtins.genList (code: code) 32) ++ [ 127 ];
      escapeTable = [
        {
          from = "\\";
          to = "\\\\";
        }
        {
          from = "\"";
          to = "\\\"";
        }
      ] ++ builtins.map (code: {
        from = unicodeChar code;
        to =
          if code == 9 then
            "\\t"
          else if code == 10 then
            "\\n"
          else if code == 13 then
            "\\r"
          else
            unicodeEscape code;
      }) controlCodes;
      escapeLiteral =
        value:
        builtins.replaceStrings (builtins.map (entry: entry.from) escapeTable) (
          builtins.map (entry: entry.to) escapeTable
        ) value;
      literal = value: "\"" + escapeLiteral (builtins.toString value) + "\"";

      controlCharacters = builtins.concatStringsSep "" (
        builtins.map unicodeChar (builtins.filter (code: code != 0) (builtins.genList (code: code) 32) ++ [ 127 ])
      );
      isLinkable =
        value:
        builtins.isString value
        && builtins.match ("https?:[^ <>\"{}|^`\\\\" + controlCharacters + "]+") value != null;

      uniqueInOrder =
        values:
        builtins.foldl' (acc: value: if builtins.elem value acc then acc else acc ++ [ value ]) [ ] values;

      aboutOf =
        id:
        let about = (defOf id).about or [ ]; in
        uniqueInOrder (builtins.filter isLinkable (if builtins.isList about then about else [ ]));

      describe =
        node:
        let
          def = defOf node.step;
          nodeIri = iriOf node;
          name = def.name or "";
          label =
            if builtins.isString name && nixpkgs.lib.trim name != "" then name else node.step;
          template = def.type or "";
          output = builtins.tryEval (steps.${node.step}.outPath);
          derivedIris = uniqueInOrder (
            builtins.sort (a: b: a < b) (
              builtins.filter (iri: iri != nodeIri) (
                builtins.map (
                  reference: iriOf (resolveReference reference)
                ) (
                  builtins.filter (reference: stepDefs ? ${referenceStep reference}) (
                    directReferencesOf node.step
                  )
                )
              )
            )
          );
          about = aboutOf node.step;
          clauses =
            [
              {
                predicate = "a";
                objects = [ "prov:Plan" ];
              }
              {
                predicate = "rdfs:label";
                objects = [ (literal label) ];
              }
            ]
            ++ nixpkgs.lib.optional (builtins.isString template && template != "") {
              predicate = "pointy:template";
              objects = [ (literal template) ];
            }
            ++ nixpkgs.lib.optional output.success {
              predicate = "pointy:output";
              objects = [ (literal output.value) ];
            }
            ++ nixpkgs.lib.optional (derivedIris != [ ]) {
              predicate = "prov:wasDerivedFrom";
              objects = builtins.map (iri: "<" + iri + ">") derivedIris;
            }
            ++ nixpkgs.lib.optional (about != [ ]) {
              predicate = "schema:about";
              objects = builtins.map (uri: "<" + uri + ">") about;
            };
        in
        {
          iri = nodeIri;
          inherit clauses;
        };

      renderClauses =
        clauses:
        let count = builtins.length clauses; in
        builtins.genList (
          index:
          let clause = builtins.elemAt clauses index; in
          "    "
          + clause.predicate
          + " "
          + builtins.concatStringsSep ", " clause.objects
          + (if index == count - 1 then " ." else " ;")
        ) count;

      prefixes = [
        "@prefix prov: <http://www.w3.org/ns/prov#> ."
        "@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> ."
        "@prefix schema: <https://schema.org/> ."
        "@prefix pointy: <https://pointy.cloud/ns#> ."
      ];

      orderedNodes =
        start:
        [
          start
        ]
        ++ builtins.sort nodeLess (
          builtins.filter (node: nodeKey node != nodeKey start) (collect start)
        );
    in
    {
      inherit staleDependencies noticesOf;
      turtleFor =
        path: stepId:
        let
          start = {
            inherit path;
            step = builtins.toString stepId;
          };
          entries = builtins.map describe (orderedNodes start);
          body = builtins.concatMap (entry: [ "" "<${entry.iri}>" ] ++ renderClauses entry.clauses) entries;
        in
        builtins.unsafeDiscardStringContext (builtins.concatStringsSep "\n" (prefixes ++ body) + "\n");
    };

  evalStepDefs =
    { stepDefs, ... }:
    builtins.mapAttrs (id: stepDef: stepDef // { id = nixpkgs.lib.toIntBase10 id; }) stepDefs;

  evalDependencies =
    { stepDefs, templates, metas, ... }:
    let
      directDepsOf =
        id:
        let
          stepDef = stepDefs.${id};
          meta = metas.${stepDef.type} or { subjectParams = [ ]; };
          kind = templates.${stepDef.type}.pointy.type or { };
        in
        if kind ? derivation then
          builtins.concatMap (subjectRefs stepDef.args) meta.subjectParams
        else
          [ ];

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

      globalPaths = [
        "flake.nix"
        "pointy.nix"
        "templates"
        "packages"
        "main.pointy"
      ];

      loadRepo =
        args:
        let
          src = args.src or args.inputs.self.outPath;
          globalSrc = copyPaths { inherit src; paths = globalPaths; };
          cfg = import (globalSrc + "/pointy.nix") {
            lib = nixpkgs.lib;
            inputs = builtins.removeAttrs args.inputs [ "self" ];
          };
        in
        {
          inherit src globalSrc cfg;
          rev = args.inputs.self.rev or null;
        };
    in
    args@{ inputs, modules ? [ ], ... }:
    flake-parts.lib.mkFlake (withDefaultNixpkgs (builtins.intersectAttrs { inherit inputs; nixpkgs = null; } args)) {
      imports = [ self.flakeModules.default ] ++ modules;

      systems = [ "x86_64-linux" ];

      _module.args.pointyRepo = loadRepo args;
    };
}
