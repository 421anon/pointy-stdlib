{ lib }:
let
  keysFor =
    shape:
    {
      scalar = [ "description" "displayName" "widget" "autocomplete" "readOnly" "path" ];
      subject = [ "description" "displayName" "widget" "allowedTypes" "quickCreate" ];
      choice = [ "description" "displayName" "widget" "enumDisplayNames" ];
      array = [ "description" "displayName" "widget" "list" ];
      record = [ "description" "displayName" "record" ];
    }
    .${shape.kind or "data"} or [ ];

  checkKeys =
    path: shape: b:
    let
      unknown = builtins.filter (k: !builtins.elem k (keysFor shape)) (builtins.attrNames b);
    in
    assert
      unknown == [ ]
      || throw "pointy template: unknown override(s) at ${path}: ${lib.concatStringsSep ", " unknown}";
    b;

  widgetKinds = [ "text" "textarea" "code" "command" "number" "checkbox" "select" "tokens" "list" "step" "steps" "record" "datetime" ];

  widgetParams = {
    code = [ "language" ];
    command = [ "prefix" ];
    text = [ "hook" ];
    tokens = [ "hook" ];
  };

  requiredParams = {
    code = [ "language" ];
    command = [ "prefix" ];
  };

  widgetsFor =
    shape:
    let
      kind = shape.kind or "data";
      element = shape.element or { };
    in
    {
      subject = [ "step" ];
      choice = [ "select" ];
      record = [ "record" ];
    }
    .${kind} or (
      if kind == "array" then
        if (element.kind or "data") == "subject" then
          [ "steps" ]
        else if (element.scalar or "data") == "text" then
          [ "tokens" ]
        else
          [ "list" ]
      else if (shape.scalar or "data") == "boolean" then
        [ "checkbox" ]
      else if (shape.scalar or "data") == "integer" then
        [ "number" "text" ]
      else
        [ "text" "textarea" "code" "command" ]
    );

  widgetFor =
    path: shape: b:
    let
      allowed = widgetsFor shape;
      default =
        {
          kind = builtins.head allowed;
        }
        // lib.optionalAttrs
          ((b ? autocomplete) && builtins.elem (builtins.head allowed) [ "tokens" "text" ])
          { hook = b.autocomplete; };
      resolved = b.widget or default;
      kind = resolved.kind or (throw "pointy template: widget at ${path} has no `kind`");
      params = widgetParams.${kind} or [ ];
      missing = builtins.filter (p: !(resolved ? ${p})) (requiredParams.${kind} or [ ]);
      extra = builtins.filter (k: k != "kind" && !builtins.elem k params) (builtins.attrNames resolved);
    in
    assert
      builtins.elem kind widgetKinds
      || throw "pointy template: unknown widget `${kind}' at ${path}; known widgets: ${lib.concatStringsSep ", " widgetKinds}";
    assert
      builtins.elem kind allowed
      || throw "pointy template: widget `${kind}' cannot drive the shape at ${path}; expected ${lib.concatStringsSep " or " allowed}";
    assert
      missing == [ ]
      || throw "pointy template: widget `${kind}' at ${path} needs ${lib.concatStringsSep ", " missing}";
    assert
      extra == [ ]
      || throw "pointy template: widget `${kind}' at ${path} takes no ${lib.concatStringsSep ", " extra}";
    resolved;

  shapeOf =
    path: shape: b:
    let
      kind = shape.kind or "data";
      scalarNames = {
        text = "text";
        integer = "int";
        boolean = "bool";
      };
    in
    checkKeys path shape b
    |> (
      _:
      {
        scalar = {
          kind = scalarNames.${shape.scalar or "text"} or "text";
          inherit (shape) scalar;
        };
        choice = {
          kind = "choice";
          options = map (v: { value = v; } // lib.optionalAttrs ((b.enumDisplayNames or { }) ? ${v}) {
            label = b.enumDisplayNames.${v};
          }) shape.values;
        };
        array = {
          kind = "list";
          element = valueOf (path + ".list") shape.element (b.list or { });
        };
        record =
          let
            overrides = (b.record or { }).fields or { };
            unknown = builtins.filter (
              f: !builtins.any (x: x.name == f) shape.fields
            ) (builtins.attrNames overrides);
          in
          assert
            unknown == [ ]
            || throw "pointy template: unknown record field override(s) at ${path}.fields: ${lib.concatStringsSep ", " unknown}";
          {
            kind = "record";
            fields = map (
              f:
              fieldOf (path + ".fields." + f.name) f.name { required = true; default = null; } f.shape (
                overrides.${f.name} or { }
              )
            ) shape.fields;
          };
        subject = {
          kind = "artifact";
          accepts = b.allowedTypes or [ ];
          create = b.quickCreate or false;
        };
      }
      .${kind} or (throw "pointy core schema: unrenderable shape kind `${kind}' at ${path}")
    );

  valueOf = path: shape: b: {
    widget = widgetFor path shape b;
    shape = shapeOf path shape b;
  };

  fieldOf = path: name: core: shape: b: {
    inherit name;
    label = b.displayName or null;
    help = b.description or "";
    readOnly = b.readOnly or false;
    inherit (core) required default;
  }
  // lib.optionalAttrs (b ? path) { inherit (b) path; }
  // valueOf path shape b;

  downloadTimestamp = {
    name = "downloadedAt";
    label = "Downloaded at";
    help = "UTC timestamp when the URL was downloaded";
    readOnly = true;
    required = false;
    default = null;
    path = [
      "downloaded"
      "downloadedAt"
    ];
    widget = {
      kind = "datetime";
    };
    shape = {
      kind = "text";
      scalar = "text";
    };
  };

  renderTemplate =
    name: tpl: metas:
    let
      meta = metas.${name};
      bindings = tpl.bindings or { };
      kind = tpl.pointy.type;
    in
    {
      inherit (tpl) displayName description sortKey;
      icon = tpl.icon or null;
      kind =
        if kind ? derivation then
          "derivation"
        else if kind ? fileUpload then
          "upload"
        else if kind ? download then
          "download"
        else
          throw "pointy template `${name}': unknown step kind";
      fields =
        map (
          p:
          fieldOf (meta.interface + "." + p.param) p.param {
            inherit (p) required;
            inherit (p) default;
          } p.shape (bindings.${p.param} or { })
        ) meta.params
        ++ lib.optionals (kind ? download) [ downloadTimestamp ];
    }
    // lib.optionalAttrs (kind ? derivation) { withSrcFiles = kind.derivation.withSrcFiles or false; }
    // lib.optionalAttrs (kind ? fileUpload) { accepts = kind.fileUpload.allowedExtensions; };

  renderStepConfig =
    { templates, metas }:
    {
      version = 4;
      templates = builtins.mapAttrs (name: tpl: renderTemplate name tpl metas) templates;
    };
in
{
  inherit renderStepConfig;
}
