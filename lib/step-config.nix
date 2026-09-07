# Pure host merge: the pointy core argument schema merged with a host's
# optional presentation overrides (template `bindings`) into the
# frontend's stepConfig document, plus the adapter-vs-schema conformance
# gate.
#
# This module is nixpkgs-free: the stepConfig derivation and the host
# conformance check run nix-instantiate over it as a build step.  The
# schema's shape, finite domain, default, and requiredness are always
# authoritative.
#
# The bindings table is optional presentation overrides: an authored
# binding may narrow (show a dropdown on a String param, allow a
# reference type, pick a widget, rename/label, autocomplete) — shape,
# domain, default, and requiredness stay the core's.  Binding keys are
# limited to presentation fields (`description`, `displayName`,
# `display`, `autocomplete`, choice narrowing); non-presentation keys
# such as `default` or `int` are rejected.
#
# Pure and nixpkgs-free: runnable from nix-instantiate (the stepConfig
# derivation and the conformance check) and from the pointy-stdlib lib
# surface.
{
}:
let
  schemaVersion = 1;
  schemaFormat = "pointy-argument-schema";

  # Throws unless the payload is a canonical, versioned core schema.
  # Returns the [interfaces] table.
  readSchema = schema:
    let
      format = schema.format or (throw "pointy core schema: missing `format`");
      version = schema.version or (throw "pointy core schema: missing `version`");
      _ =
        if format != schemaFormat then
          throw "pointy core schema: unsupported format `${format}` (expected `pointy-argument-schema`)"
        else if version != schemaVersion then
          throw "pointy core schema: unsupported version `${toString version}` (expected ${toString schemaVersion}); the host adapter must be upgraded"
        else null;
      forced = builtins.seq _ null;
    in
    builtins.seq forced schema.interfaces;

  # Normalize a core shape: the core emits `array` for a list wire
  # shape, so accept both spellings.
  normShape = s:
    if s != null && s ? kind && s.kind == "array" then
      s // { kind = "list"; }
    else
      s;

  scalarIsString = s: s == "text";
  scalarIsInt = s: s == "integer";

  __unique = xs: builtins.foldl' (acc: x: if builtins.elem x acc then acc else acc ++ [ x ]) [ ] xs;

  isSubjectKind = kind:
    kind == "subject" || kind == "subjects" || kind == "listSubject";

  # ---- presentation overlay validation -------------------------------
  #
  # The binding node for one shape position.  Allowed presentation keys
  # per shape; non-presentation keys fail.

  allowedOverlayKeys = shape: kind:
    if isSubjectKind kind then
      [ "description" "displayName" "allowedTypes" "quickCreate" ]
    else
      let
        k = shape.kind or (throw "pointy core schema: parameter has no shape");
      in
      if k == "scalar" then
        if scalarIsString shape.scalar then
          [ "description" "displayName" "display" "autocomplete" "enum" ]
        else if scalarIsInt shape.scalar then
          [ "description" "displayName" "display" "autocomplete" ]
        else
          [ "description" "displayName" "display" ]
      else if k == "choice" then
        [ "description" "displayName" "enumDisplayNames" "visibleValues" ]
      else if k == "list" then
        [ "description" "displayName" "list" ]
      else if k == "record" then
        [ "description" "displayName" "record" ]
      else
        throw "pointy core schema: unrenderable shape kind `${k}` (scalar/choice/list/record render in stepConfig)";

  checkOverlayKeys = path: shape: kind: node:
    let
      allowed = allowedOverlayKeys shape kind;
      unknown = builtins.filter (k: !builtins.elem k allowed) (builtins.attrNames node);
    in
    if unknown == [ ] then
      null
    else
      throw "pointy template: unknown presentation override(s) at ${path}: ${builtins.concatStringsSep ", " unknown} (allowed: ${builtins.concatStringsSep ", " allowed})";

  # Validate one overlay against a shape position; throws on violation.
  validateOverlay = path: shape0: kind: node:
    builtins.seq
      (checkOverlayKeys path (normShape shape0) kind node)
      (
        let
          shape = normShape shape0;
        in
        if isSubjectKind kind then
          null
        else if node ? list then
          validateOverlay (path + ".list") (normShape shape.element) null node.list
        else if node ? record then
          let
            rec_ = node.record;
            _ =
              if builtins.attrNames rec_ == [ "fields" ] then
                null
              else
                throw "pointy template: ${path}.record overlay key is `fields` (found: ${builtins.concatStringsSep ", " (builtins.attrNames rec_)})";
            fieldOverlays = rec_.fields or (throw "pointy template: ${path} is missing `fields`");
            unknownFields = builtins.filter (f: !(builtins.any (x: x.name == f) shape.fields)) (builtins.attrNames fieldOverlays);
            checkFields = builtins.seq (
              if unknownFields == [ ] then
                null
              else
                throw "pointy template: unknown record field override(s) at ${path}.fields: ${builtins.concatStringsSep ", " unknownFields}"
            ) null;
          in
          builtins.seq
            checkFields
            (builtins.foldl'
              (acc: f:
                (validateOverlay
                    (path + ".fields.${f.name}")
                    (normShape f.shape)
                    null
                    (fieldOverlays.${f.name} or { })
                  == null)
                && acc)
              true
              shape.fields)
        else
          null
      );

  # ---- rendering -----------------------------------------------------

  # The `type` payload of one argument (frontend StepArgType): one of
  # string / int / enum / list / record / step.
  stepArgType = shape0: kind: node:
    let
      shape = normShape shape0;
      b = if node == null then { } else node;
    in
    if isSubjectKind kind then
      if kind == "subjects" then
        { list = { step = stepAttrs b; }; }
      else
        { step = stepAttrs b; }
    else if shape == null then
      # untypable parameter (a schema error surfaced by the core check);
      # never guess a semantic type.
      throw "pointy core schema: parameter has no renderable shape"
    else if shape.kind == "scalar" then
      let
        display = b.display or { };
        auto =
          if b ? autocomplete then
            { autocomplete = b.autocomplete; }
          else
            { };
      in
      if scalarIsString shape.scalar then
        if b ? enum then
          let
            e = b.enum;
            checkValues = builtins.seq (
              if e ? values then null else throw "pointy template: enum override is missing `values`"
            ) null;
            forced = builtins.seq checkValues e.values;
          in
          {
            enum = forced;
            enumDisplayNames = e.displayNames or { };
          }
        else
          {
            string = {
              inherit display;
            } // auto;
          }
      else if scalarIsInt shape.scalar then
        {
          int = {
            inherit display;
          } // auto;
        }
      else
        # decimal / boolean / custom scalars have no notebook wire type;
        # rendering them as strings would mis-type values the core
        # requires as JSON bool/decimal and break record round-trips.
        # Reject loudly so the host adds a wire type or keeps such a
        # parameter out of the UI.
        throw "pointy core schema: scalar `${shape.scalar}` has no notebook wire type (`text`/`integer` render); add a UI wire type or omit the parameter from stepConfig"
    else if shape.kind == "choice" then
      let
        domain = shape.values;
        visible = b.visibleValues or [ ];
        _rejectWiden = builtins.seq (
          if builtins.foldl' (acc: v: acc && builtins.elem v domain) true visible then
            null
          else
            throw "pointy template: `visibleValues` on a choice parameter names value(s) outside the core domain (a host may narrow, never widen)"
        ) null;
        enum = builtins.seq _rejectWiden (if b ? visibleValues then visible else domain);
      in
      {
        inherit enum;
        enumDisplayNames = b.enumDisplayNames or { };
      }
    else if shape.kind == "list" then
      {
        list = stepArgType shape.element null (b.list or { });
      }
    else if shape.kind == "record" then
      let
        recordOverlay =
          if b ? record then
            (b.record.fields or { })
          else
            { };
      in
      {
        record = {
          fields = builtins.listToAttrs (
            builtins.map
              (f: {
                name = f.name;
                value = argType (normShape f.shape) null (recordOverlay.${f.name} or { });
              })
              shape.fields
          );
        };
      }
    else
      throw "pointy core schema: unrenderable shape kind `${shape.kind}` (scalar/choice/list/record render in stepConfig)";

  stepAttrs = b:
    (if b ? allowedTypes then { inherit (b) allowedTypes; } else { })
    // (if b.quickCreate or false then { quickCreate = true; } else { });

  # The full ArgType of one argument: { description, displayName, type }.
  argType = shape0: kind: node:
    let
      b = if node == null then { } else node;
    in
    {
      description = b.description or "";
      displayName = b.displayName or null;
      type = stepArgType shape0 kind b;
    };

  semanticArg = schemaParam: node:
    argType (schemaParam.shape or null) (schemaParam.kind or null) node
    // (if schemaParam ? default && schemaParam.default != null then
      { inherit (schemaParam) default; }
    else
      { });

  builderArg = node:
    {
      description = node.description or "";
      displayName = node.displayName or null;
      inherit (node) type;
    };

  # ---- full merged stepConfig document --------------------------------
  #
  # adapter: { <name> = { interface; parameters; bindings; builderArgs;
  #                        sortKey; displayName; description; icon;
  #                        pointyType }; ... }
  #   parameters = [ { param; option ? param; kind ?; default ? } ... ]
  renderStepConfig = { schema, adapter }:
    let
      interfaces = readSchema schema;
    in
    builtins.mapAttrs (
      name: tpl:
      let
        ifaceName = tpl.interface or (throw "pointy template `${name}': missing `interface`");
        iface = interfaces.${ifaceName} or (throw "pointy template `${name}': interface `${ifaceName}' is not declared by the core schema");
        schemaParams = iface.parameters or [ ];
        params = tpl.parameters or [ ];
        bindings = tpl.bindings or { };
        builderArgs = tpl.builderArgs or { };
        _covered = checkParamCoverage name ifaceName schemaParams params;
        validatedOverlays = builtins.foldl' (
          acc: sp:
          (validateOverlay
              (ifaceName + "." + sp.parameter)
              (sp.shape or null)
              (sp.kind or null)
              (bindings.${sp.parameter} or { })
            == null)
          && acc
        ) true schemaParams;
        _validate = builtins.seq _covered validatedOverlays;
        optionOf = p:
          (builtins.head (builtins.filter (x: x.param == p) params)).option or p;
        args = builtins.seq _validate (builtins.listToAttrs (
          builtins.map (sp: {
            name = optionOf sp.parameter;
            value = semanticArg sp (bindings.${sp.parameter} or { });
          }) schemaParams
          ++ builtins.map (n: {
            name = n;
            value = builderArg builderArgs.${n};
          }) (builtins.attrNames builderArgs)
        ));
        type =
          if tpl ? pointyType && tpl.pointyType ? derivation then
            {
              derivation = tpl.pointyType.derivation // { inherit args; };
            }
          else
            tpl.pointyType;
      in
      {
        sortKey = tpl.sortKey or null;
        displayName = tpl.displayName or null;
        description = tpl.description or null;
        icon = tpl.icon or null;
        inherit type;
      }
    ) adapter;

  checkParamCoverage = name: ifaceName: schemaParams: params:
    let
      schemaNames = builtins.map (sp: sp.parameter) schemaParams;
      paramNames = builtins.map (p: p.param) params;
      missing = builtins.filter (p: !builtins.elem p paramNames) schemaNames;
      extra = builtins.filter (p: !builtins.elem p schemaNames) paramNames;
      dup = builtins.filter (
        n: builtins.length (builtins.filter (x: x == n) paramNames) > 1
      ) (__unique paramNames);
      problems =
        (if missing == [ ] && extra == [ ] then
          [ ]
        else
          [ "contract parameters for interface `${ifaceName}' disagree with the core (missing: ${builtins.concatStringsSep ", " missing}; extra: ${builtins.concatStringsSep ", " extra})" ])
        ++ (if dup == [ ] then
          [ ]
        else
          [ "duplicate contract parameters `${builtins.concatStringsSep ", " dup}'" ]);
    in
    if problems == [ ] then null else throw "pointy template `${name}': ${builtins.concatStringsSep "; " problems}";

  # ---- host conformance ----------------------------------------------

  # Adapter table vs core schema, minus the vacuity probes.  Returns the
  # flat list of problems the gate must require empty.
  problemsCore = { schema, adapter, templateNames }:
    let
      interfaces = readSchema schema;
      structural = builtins.concatLists (
        builtins.attrValues (
          builtins.mapAttrs (
            name: tpl:
            let
              ifaceName = tpl.interface or "";
              iface = interfaces.${ifaceName} or null;
              schemaParams = if iface != null then iface.parameters or [ ] else [ ];
              schemaNames = builtins.map (sp: sp.parameter) schemaParams;
              paramNames = builtins.map (p: p.param) (tpl.parameters or [ ]);
              bindings = tpl.bindings or { };
              builderArgNames = builtins.attrNames (tpl.builderArgs or { });
            in
            (if ifaceName == "" then
              [ "${name}: missing `interface`" ]
            else if iface == null then
              [ "${name}: interface `${ifaceName}` is not declared by the core schema" ]
            else
              [ ])
            ++ (let unknown = builtins.filter (p: !builtins.elem p schemaNames) paramNames;
              in
              builtins.map (p: "${name}: contract parameter `${p}` is not a core parameter of `${ifaceName}`") unknown)
            ++ (let missing = builtins.filter (p: !builtins.elem p paramNames) schemaNames;
              in
              builtins.map (p: "${name}: core parameter `${p}` has no adapter entry") missing)
            ++ (let dup = builtins.filter (
              n: builtins.length (builtins.filter (x: x == n) paramNames) > 1
            ) (__unique paramNames);
              in
              builtins.map (n: "${name}: duplicate contract parameter `${n}`") dup)
            ++ (let unknown = builtins.filter (p: !builtins.elem p schemaNames) (builtins.attrNames bindings);
              in
              builtins.map (p: "${name}: unknown binding `${p}` (not a core parameter)") unknown)
            ++ (let coll = builtins.filter (p: builtins.elem p schemaNames) builderArgNames;
              in
              builtins.map (p: "${name}: builder argument `${p}` collides with a core parameter") coll)
            ++ (builtins.concatLists (
              builtins.map (p: if iface != null then kindAgreement name schemaParams p else [ ]) (tpl.parameters or [ ])
            ))
            ++ (builtins.concatLists (
              builtins.map (p: if iface != null then defaultAgreement name schemaParams p else [ ]) (tpl.parameters or [ ])
            ))
            ++ (builtins.concatLists (
              builtins.map (sp: allowedTypesAgreement name sp bindings templateNames) schemaParams
            ))
          ) adapter
        )
      );
      kindAgreement = name: schemaParams: p:
        let
          sp = builtins.head (builtins.filter (x: x.parameter == p.param) schemaParams);
          coreKind = sp.kind or null;
        in
        if p ? kind && coreKind != null && p.kind != coreKind then
          [ "${name}: authored kind `${p.kind}` for `${p.param}` disagrees with the core kind `${coreKind}`" ]
        else if p ? kind && coreKind == null then
          [ "${name}: authored kind `${p.kind}` for `${p.param}` but the core declares no kind" ]
        else
          [ ];
      defaultAgreement = name: schemaParams: p:
        if p ? default && p.default != null then
          let
            sp = builtins.head (builtins.filter (x: x.parameter == p.param) schemaParams);
            coreDefault = sp.default or null;
          in
          if coreDefault != null && p.default != coreDefault then
            [ "${name}: construction default `${builtins.toJSON p.default}` for `${p.param}` disagrees with the core default `${builtins.toJSON coreDefault}`" ]
          else
            [ ]
        else
          [ ];
      allowedTypesAgreement = name: sp: bindings: tplNames:
        if isSubjectKind (sp.kind or null) then
          let
            allowed = (bindings.${sp.parameter} or { }).allowedTypes or [ ];
            unknown = builtins.filter (t: !builtins.elem t tplNames) allowed;
          in
          builtins.map (t: "${name}: allowedTypes value `${t}` names no template") unknown
        else
          [ ];
      mergeProblems = builtins.concatLists (
        builtins.attrValues (
          # toJSON deep-forces each template document so overlay/shape
          # violations surface here (a lazy WHNF tryEval would miss them).
          builtins.mapAttrs (
            name: _:
            let
              r = builtins.tryEval (builtins.toJSON ((renderStepConfig { inherit schema adapter; }).${name}));
            in
            if r.success then [ ] else [ "${name}: merge rejected over the core schema (validation error; see the stepConfig build for detail)" ]
          ) adapter
        )
      );
    in
    structural ++ mergeProblems;

  # The gate must not be vacuous: adapters that provably break a rule
  # have to surface a problem.  Computed against the live schema so the
  # probes stay meaningful when the corpus grows.
  probes = schema: adapter: templateNames: interfaces:
    let
      ifaceNames = builtins.attrNames interfaces;
    in
    if ifaceNames == [ ] then
      [ ]
    else
      let
        ifaceName = builtins.head ifaceNames;
        schemaParams = interfaces.${ifaceName}.parameters or [ ];
        paramNames = builtins.map (sp: sp.parameter) schemaParams;
        badUnknownBinding = problemsCore {
          inherit schema;
          adapter = {
            __probe = {
              interface = ifaceName;
              parameters = builtins.map (p: { param = p; }) paramNames;
              bindings = { doesNotExist = { description = ""; }; };
              pointyType = { derivation = { withSrcFiles = false; }; };
              builderArgs = { };
            };
          };
          inherit templateNames;
        };
        badKind = problemsCore {
          inherit schema;
          adapter = {
            __probe = {
              interface = ifaceName;
              parameters = builtins.map (p: { param = p; kind = "subjects"; }) paramNames;
              bindings = { };
              builderArgs = { };
              pointyType = { derivation = { withSrcFiles = false; }; };
            };
          };
          inherit templateNames;
        };
      in
      (if builtins.length badUnknownBinding == 0 then
        [ "probe `unknown-binding`: not rejected (gate is vacuous)" ]
      else
        [ ])
      ++ (if builtins.length badKind == 0 then
        [ "probe `kind-disagreement`: not rejected (gate is vacuous)" ]
      else
        [ ]);

  validateHostAdapter = { schema, adapter, templateNames ? null }:
    let
      tplNames =
        if templateNames == null then
          builtins.attrNames adapter
        else
          templateNames;
      interfaces = readSchema schema;
    in
    problemsCore { inherit schema adapter; templateNames = tplNames; }
    ++ probes schema adapter tplNames interfaces;
in
{
  inherit schemaVersion schemaFormat readSchema renderStepConfig validateHostAdapter;
}
