# Renders the notebook's stepConfig document from the core tables
# (`templateMeta`) plus each template's presentation bindings.
let
  baseKeys = [ "description" "displayName" ];

  isSubjectKind = kind:
    kind == "subject" || kind == "subjects" || kind == "listSubject";

  # Presentation keys the core kind/shape accepts.
  allowedKeys = kind: shape:
    if isSubjectKind kind then
      [ "allowedTypes" "quickCreate" ]
    else if shape == null then
      [ ]
    else
      {
        scalar = [ "display" "autocomplete" ];
        choice = [ "enumDisplayNames" ];
        array = [ "list" ];
        record = [ "record" ];
      }
      .${shape.kind} or [ ];

  rejectUnknown = path: kind: shape: node:
    let
      unknown = builtins.filter (k: !builtins.elem k (baseKeys ++ allowedKeys kind shape)) (
        builtins.attrNames node
      );
    in
    if unknown == [ ] then
      null
    else
      throw "pointy template: unknown presentation override(s) at ${path}: ${builtins.concatStringsSep ", " unknown}";

  stepAttrs = b:
    (if b ? allowedTypes then { inherit (b) allowedTypes; } else { })
    // (if b.quickCreate or false then { quickCreate = true; } else { });

  stringAttrs = b:
    { display = b.display or { }; }
    // (if b ? autocomplete then { inherit (b) autocomplete; } else { });

  # core shape -> notebook wire type.  `kind` is null for record fields
  # and list elements, which carry no acquisition kind.
  wireType = path: kind: shape: node:
    let
      b = if node == null then { } else node;
      rendered =
        if isSubjectKind kind then
          if kind == "subjects" then
            { list = { step = stepAttrs b; }; }
          else
            { step = stepAttrs b; }
        else if shape == null then
          throw "pointy core schema: parameter has no renderable shape"
        else if shape.kind == "scalar" then
          if shape.scalar == "text" then
            { string = stringAttrs b; }
          else if shape.scalar == "integer" then
            { int = stringAttrs b; }
          else
            throw "pointy core schema: scalar `${shape.scalar}` has no notebook wire type"
        else if shape.kind == "choice" then
          {
            enum = shape.values;
            enumDisplayNames = b.enumDisplayNames or { };
          }
        else if shape.kind == "array" then
          { list = wireType (path + ".list") null shape.element (b.list or { }); }
        else if shape.kind == "record" then
          let
            overlays = if b ? record then b.record.fields or (throw "pointy template: ${path} is missing `fields`") else { };
            unknownFields = builtins.filter (
              f: !(builtins.any (x: x.name == f) shape.fields)
            ) (builtins.attrNames overlays);
          in
          builtins.seq (
            if unknownFields == [ ] then
              null
            else
              throw "pointy template: unknown record field override(s) at ${path}.fields: ${builtins.concatStringsSep ", " unknownFields}"
          ) {
            record.fields = builtins.listToAttrs (
              builtins.map
                (f: {
                  name = f.name;
                  value = argType (path + ".fields." + f.name) null f.shape (overlays.${f.name} or { });
                })
                shape.fields
            );
          }
        else
          throw "pointy core schema: unrenderable shape kind `${shape.kind}`";
    in
    builtins.seq (rejectUnknown path kind shape b) rendered;

  argType = path: kind: shape: node:
    {
      description = node.description or "";
      displayName = node.displayName or null;
      type = wireType path kind shape node;
    };

  renderStepConfig = { templates, metas }:
    let
      templateNames = builtins.attrNames templates;
      document = builtins.mapAttrs (
        name: tpl:
        let
          meta = metas.${name};
          bindings = tpl.bindings or { };
          # A binding may narrow a subject's template domain, never name a
          # template that does not exist.
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
          args = builtins.seq (
            if problems == [ ] then
              null
            else
              throw ("pointy template `${name}`: " + builtins.concatStringsSep "; " problems)
          ) (builtins.listToAttrs (
            builtins.map (p: {
              name = p.param;
              value = argType (meta.interface + "." + p.param) p.kind p.shape (bindings.${p.param} or { })
                // (if p.default != null then { inherit (p) default; } else { });
            }) meta.params
          ));
        in
        {
          sortKey = tpl.sortKey or null;
          displayName = tpl.displayName or null;
          description = tpl.description or null;
          icon = tpl.icon or null;
          type =
            if tpl.pointy.type ? derivation then
              {
                derivation = tpl.pointy.type.derivation // { inherit args; };
              }
            else
              tpl.pointy.type;
        }
      ) templates;
    in
    builtins.deepSeq document document;
in
{
  inherit renderStepConfig;
}
