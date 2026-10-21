{ nixpkgs, pointyLib, ... }:
let
  applicationOf =
    { stepDefs, metas }:
    id:
    let
      def = stepDefs.${id} or (throw "pointy.step ${id}: the step is not defined");
      meta =
        metas.${def.type}
          or (throw "pointy.step ${id}: no template declares the type `${def.type}'");
      refs = pointyLib.subjectRefs (def.args or (throw "pointy.step ${id}: the definition has no args"));
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
in
{
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
      refs = pointyLib.subjectRefs (def.args or (throw "pointy.step ${id}: the definition has no args"));
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
}
