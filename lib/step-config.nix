# Renders the notebook's stepConfig document from the core tables
# (`templateMeta`) plus each template's presentation bindings.
{ lib, arityOf }:
let
  baseKeys = [ "description" "displayName" ];

  # An artifact position: the subject leaf, or the ordered list of
  # subject leaves whose empty form is legal.
  isSubject = shape: arityOf shape != null;

  allowedKeys =
    shape:
    {
      # A checkbox carries no presentation knobs.
      scalar = { boolean = [ ]; }.${shape.scalar or "data"} or [ "display" "autocomplete" ];
      subject = [ "allowedTypes" "quickCreate" ];
      choice = [ "enumDisplayNames" ];
      array = [ "list" ];
      record = [ "record" ];
    }
    .${shape.kind or "data"} or [ ];

  stepAttrs = b:
    lib.optionalAttrs (b ? allowedTypes) { inherit (b) allowedTypes; }
    // lib.optionalAttrs (b.quickCreate or false) { quickCreate = true; };

  stringAttrs = b:
    { display = b.display or { }; }
    // lib.optionalAttrs (b ? autocomplete) { inherit (b) autocomplete; };

  # core shape -> notebook wire type.  An artifact position renders as the
  # notebook's step descriptor; every other shape renders by its wire form.
  wireType =
    path: shape: b:
    let
      kind = shape.kind or "data";
      scalar = shape.scalar or "data";
      unknownKeys = builtins.filter (
        k: !builtins.elem k (baseKeys ++ allowedKeys shape)
      ) (builtins.attrNames b);
      wire = {
        subject = { step = stepAttrs b; };
        array = { list = wireType (path + ".list") shape.element (b.list or { }); };
        scalar = {
          text = { string = stringAttrs b; };
          integer = { int = stringAttrs b; };
          boolean = { bool = { }; };
        }
        .${scalar} or (throw "pointy core schema: scalar `${scalar}` has no notebook wire type");
        choice = {
          enum = shape.values;
          enumDisplayNames = b.enumDisplayNames or { };
        };
        record =
          let
            fields = (b.record or { }).fields or { };
            unknownFields = builtins.filter (
              f: !(builtins.any (x: x.name == f) shape.fields)
            ) (builtins.attrNames fields);
          in
          assert
            !(b ? record) || b.record ? fields || throw "pointy template: ${path} is missing `fields`";
          assert
            unknownFields == [ ]
            || throw "pointy template: unknown record field override(s) at ${path}.fields: ${builtins.concatStringsSep ", " unknownFields}";
          {
            record.fields = builtins.listToAttrs (
              builtins.map
                (f: {
                  name = f.name;
                  value = argType (path + ".fields." + f.name) f.shape (fields.${f.name} or { });
                })
                shape.fields
            );
          };
      };
    in
    assert shape != null || throw "pointy core schema: parameter has no renderable shape";
    assert
      unknownKeys == [ ]
      || throw "pointy template: unknown presentation override(s) at ${path}: ${builtins.concatStringsSep ", " unknownKeys}";
    wire.${kind} or (throw "pointy core schema: unrenderable shape kind `${kind}`");

  argType = path: shape: b:
    {
      description = b.description or "";
      displayName = b.displayName or null;
      type = wireType path shape b;
    };

  renderStepConfig = { templates, metas }:
    let
      templateNames = builtins.attrNames templates;
      document = builtins.mapAttrs (
        name: tpl:
        let
          meta = metas.${name};
          bindings = tpl.bindings or { };
          paramNames = builtins.map (p: p.param) meta.params;
          unknownBindings = builtins.filter (n: !builtins.elem n paramNames) (
            builtins.attrNames bindings
          );
          # A binding may narrow a subject's template domain; a list keeps its
          # leaves' knobs under `list`.
          narrows =
            p:
            if arityOf p.shape == "many" then
              (bindings.${p.param} or { }).list or { }
            else
              bindings.${p.param} or { };
          problems = builtins.concatMap
            (p:
              builtins.map
                (t: "allowedTypes value `${t}' names no template")
                (builtins.filter
                  (t: !builtins.elem t templateNames)
                  ((narrows p).allowedTypes or [ ])))
            (builtins.filter (p: isSubject p.shape) meta.params);
          args =
            assert
              unknownBindings == [ ]
              || throw (
                "pointy.template `${name}`: "
                + lib.concatStringsSep "; " (
                  builtins.map (n: "unknown binding `${n}': not a core parameter of `${meta.interface}'") unknownBindings
                )
              );
            assert
              problems == [ ]
              || throw ("pointy template `${name}`: " + builtins.concatStringsSep "; " problems);
            builtins.listToAttrs (
              builtins.map (p: {
                name = p.param;
                value = argType (meta.interface + "." + p.param) p.shape (bindings.${p.param} or { })
                  // lib.optionalAttrs (p.default != null) { inherit (p) default; };
              }) meta.params
            );
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
