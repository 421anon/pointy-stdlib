# Renders the notebook's stepConfig document from the contract tables
# (`templateMeta`) plus each template's presentation bindings.
let
  normShape = s:
    if s != null && s ? kind && s.kind == "array" then
      s // { kind = "list"; }
    else
      s;

  scalarIsString = s: s == "text";
  scalarIsInt = s: s == "integer";

  isSubjectKind = kind:
    kind == "subject" || kind == "subjects" || kind == "listSubject";

  # ---- rendering -----------------------------------------------------

  baseKeys = [ "description" "displayName" ];

  rejectUnknown = path: allowed: node:
    let
      unknown = builtins.filter (k: !builtins.elem k allowed) (builtins.attrNames node);
    in
    if unknown == [ ] then
      null
    else
      throw "pointy template: unknown presentation override(s) at ${path}: ${builtins.concatStringsSep ", " unknown} (allowed: ${builtins.concatStringsSep ", " allowed})";

  stepArgType = path: shape0: kind: node:
    let
      shape = normShape shape0;
      b = if node == null then { } else node;
      checked = allowed: builtins.seq (rejectUnknown path allowed b) null;
    in
    if isSubjectKind kind then
      builtins.seq (checked (baseKeys ++ [ "allowedTypes" "quickCreate" ]))
        (
          if kind == "subjects" then
            { list = { step = stepAttrs b; }; }
          else
            { step = stepAttrs b; }
        )
    else if shape == null then
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
        builtins.seq (checked (baseKeys ++ [ "display" "autocomplete" "enum" ]))
          (
            if b ? enum then
              let
                e = b.enum;
                forced = builtins.seq (
                  if e ? values then null else throw "pointy template: enum override is missing `values`"
                ) e.values;
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
          )
      else if scalarIsInt shape.scalar then
        builtins.seq (checked (baseKeys ++ [ "display" "autocomplete" ]))
          {
            int = {
              inherit display;
            } // auto;
          }
      else
        builtins.seq (checked (baseKeys ++ [ "display" ]))
          # The notebook has no wire type for decimal/boolean scalars;
          # the core requires them as JSON bool/decimal.
          (throw "pointy core schema: scalar `${shape.scalar}` has no notebook wire type (`text`/`integer` render); add a UI wire type or omit the parameter from stepConfig")
    else if shape.kind == "choice" then
      builtins.seq (checked (baseKeys ++ [ "enumDisplayNames" "visibleValues" ]))
        (
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
        )
    else if shape.kind == "list" then
      builtins.seq (checked (baseKeys ++ [ "list" ]))
        {
          list = stepArgType (path + ".list") shape.element null (b.list or { });
        }
    else if shape.kind == "record" then
      builtins.seq (checked (baseKeys ++ [ "record" ]))
        (
          let
            fieldOverlays =
              if b ? record then
                b.record.fields or (throw "pointy template: ${path} is missing `fields`")
              else
                { };
            unknownFields = builtins.filter (f: !(builtins.any (x: x.name == f) shape.fields)) (builtins.attrNames fieldOverlays);
          in
          builtins.seq (
            if unknownFields == [ ] then
              null
            else
              throw "pointy template: unknown record field override(s) at ${path}.fields: ${builtins.concatStringsSep ", " unknownFields}"
          ) {
            record = {
              fields = builtins.listToAttrs (
                builtins.map
                  (f: {
                    name = f.name;
                    value = argType (path + ".fields." + f.name) (normShape f.shape) null (fieldOverlays.${f.name} or { });
                  })
                  shape.fields
              );
            };
          }
        )
    else
      throw "pointy core schema: unrenderable shape kind `${shape.kind}` (scalar/choice/list/record render in stepConfig)";

  stepAttrs = b:
    (if b ? allowedTypes then { inherit (b) allowedTypes; } else { })
    // (if b.quickCreate or false then { quickCreate = true; } else { });

  argType = path: shape0: kind: node:
    let
      b = if node == null then { } else node;
    in
    {
      description = b.description or "";
      displayName = b.displayName or null;
      type = stepArgType path shape0 kind b;
    };

  semanticArg = path: param: node:
    let
      rendered = argType path param.shape param.kind node;
      keepDefault =
        param.default != null
        && (
          if rendered.type ? enum then
            builtins.elem param.default rendered.type.enum
          else
            true
        );
    in
    rendered // (if keepDefault then { inherit (param) default; } else { });

  builderArg = node:
    {
      description = node.description or "";
      displayName = node.displayName or null;
      inherit (node) type;
    };

  # ---- full merged stepConfig document --------------------------------
  renderStepConfig = { templates, metas }:
    let
      templateNames = builtins.attrNames templates;
      document = builtins.mapAttrs (
        name: tpl:
        let
          meta = metas.${name};
          bindings = tpl.bindings or { };
          builderArgs = tpl.builderArgs or { };
          # Presentation-only check: a host may narrow a subject's
          # template domain, never name a template that does not exist.
          problems = builtins.concatLists (
            builtins.map
              (p:
                if isSubjectKind p.kind then
                  builtins.map
                    (t: "allowedTypes value `${t}' names no template")
                    (builtins.filter
                      (t: !builtins.elem t templateNames)
                      ((bindings.${p.param} or { }).allowedTypes or [ ]))
                else
                  [ ])
              meta.params
          );
          _ =
            if problems == [ ] then
              null
            else
              throw ("pointy template `${name}`: " + builtins.concatStringsSep "; " problems);
          args = builtins.seq _ (builtins.listToAttrs (
            builtins.map (p: {
              name = p.param;
              value = semanticArg (meta.interface + "." + p.param) p (bindings.${p.param} or { });
            }) meta.params
            ++ builtins.map (n: {
              name = n;
              value = builderArg builderArgs.${n};
            }) (builtins.attrNames builderArgs)
          ));
          type =
            if tpl.pointy.type ? derivation then
              {
                derivation = tpl.pointy.type.derivation // { inherit args; };
              }
            else
              tpl.pointy.type;
        in
        {
          sortKey = tpl.sortKey or null;
          displayName = tpl.displayName or null;
          description = tpl.description or null;
          icon = tpl.icon or null;
          inherit type;
        }
      ) templates;
    in
    builtins.deepSeq document document;
in
{
  inherit renderStepConfig;
}
