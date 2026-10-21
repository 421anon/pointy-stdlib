{ nixpkgs, pointyLib, ... }:
let
  mapSubjectRefs =
    f: arity: value:
    if arity == "many" then builtins.map f value else f value;
in
{
  evalStepDefs =
    { stepDefs, ... }:
    builtins.mapAttrs (id: stepDef: stepDef // { id = nixpkgs.lib.toIntBase10 id; }) stepDefs;

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
          pointyLib = pointyLib.api;
        }
      ) templates;
      defaultRequirements = {
        ram = "1G";
        cpu = 1;
        ior = "0";
        iow = "0";
      };
      extrasFor = {
        csv = pointyLib.csvExtras;
        fastq = pointyLib.fastqExtras;
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
                      steps.${pointyLib.stepIdFromRef ref}
                        or (throw "pointy.step ${id}: the producer `${pointyLib.stepIdFromRef ref}' is not defined")
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
          builtins.concatMap (pointyLib.subjectRefs stepDef.args) meta.subjectParams
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
}
