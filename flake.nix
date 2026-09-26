{
  inputs = {
    nixpkgs.follows = "pointy-lang/nixpkgs";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    pointy-lang = {
      url = "git+ssh://git@github.com/421anon/pointy-lang";
      inputs.fixtures.url = "git+ssh://git@github.com/421anon/pointy-lang?dir=fixtures/flake";
      inputs.pointy-lang-stdlib.url = "git+ssh://git@github.com/421anon/pointy-lang-stdlib";
    };
  };

  outputs =
    inputs@{ ... }:
    let
      pointyLib = import ./lib.nix inputs;
      semantic = import ./semantic.nix {
        inherit pointyLib;
        inherit (inputs) pointy-lang;
      };
    in
    {
      lib = pointyLib.api;

      flakeModules.default =
        { lib, pointyRepo, ... }:
        let
          inherit (pointyRepo) src globalSrc cfg;
          inherit (cfg) pkgs source;

          loadIfPresent = dir: if builtins.pathExists dir then pointyLib.loadDir dir else { };

          templates = pointyLib.loadDir (globalSrc + "/templates");
          presets = loadIfPresent (src + "/presets");
          projects = loadIfPresent (src + "/projects");

          kernel = semantic { inherit pkgs source templates; };
          inherit (kernel) metas certify applicationsCheck;

          stepIds = map (name: lib.removeSuffix ".nix" name) (
            builtins.attrNames (
              lib.filterAttrs (_: type: type == "regular") (builtins.readDir (src + "/steps"))
            )
          );
          stepIdSet = builtins.listToAttrs (map (id: { name = id; value = null; }) stepIds);

          stepFiles = builtins.mapAttrs (
            id: _:
            builtins.path { path = src + "/steps/${id}.nix"; }
          ) stepIdSet;
          rawDefs = builtins.mapAttrs (id: _: import stepFiles.${id}) stepIdSet;
          allStepDefs = pointyLib.evalStepDefs { stepDefs = rawDefs; };

          metaOf = id: metas.${rawDefs.${id}.type} or { subjectParams = [ ]; };
          producersOf =
            id:
            lib.sort (a: b: a < b) (
              lib.unique (
                builtins.concatMap (p: pointyLib.subjectRefs rawDefs.${id}.args p) (metaOf id).subjectParams
              )
            );
          closureOf =
            id:
            builtins.map (node: node.key) (
              builtins.genericClosure {
                startSet = [ { key = id; } ];
                operator =
                  node:
                  builtins.map (p: { key = p; }) (
                    builtins.filter (p: stepIdSet ? ${p}) (producersOf node.key)
                  );
              }
            );
          defsOf =
            ids:
            builtins.listToAttrs (map (id: { name = id; value = allStepDefs.${id}; }) ids);
          srcDirs = builtins.mapAttrs (
            id: _:
            let
              type = rawDefs.${id}.type;
              kind = templates.${type}.pointy.type;
              dir = src + "/srcFiles/${id}";
              usesSrcDir = kind ? derivation && (kind.derivation.withSrcFiles or false);
            in
            if usesSrcDir && builtins.pathExists dir then
              {
                hasSrcDir = true;
                srcDir = builtins.path { path = dir; };
              }
            else
              {
                hasSrcDir = false;
                srcDir = dir;
              }
          ) stepIdSet;
          fileHash = path: if builtins.pathExists path then builtins.hashFile "sha256" path else "";
          keys = builtins.mapAttrs (
            id: _:
            builtins.hashString "sha256" (
              builtins.toJSON {
                version = 1;
                nix = builtins.nixVersion;
                lock = fileHash (src + "/flake.lock");
                global = toString globalSrc;
                step = toString stepFiles.${id};
                srcFiles =
                  if srcDirs.${id}.hasSrcDir then toString srcDirs.${id}.srcDir else null;
                producers = map (p: if stepIdSet ? ${p} then keys.${p} else null) (producersOf id);
              }
            )
          ) stepIdSet;

          dependencies = pointyLib.evalDependencies {
            stepDefs = allStepDefs;
            inherit templates metas;
          };

          scopes = builtins.mapAttrs (
            id: _:
            let
              defs = defsOf (closureOf id);
              steps = pointyLib.evalSteps {
                stepDefs = defs;
                inherit templates pkgs metas;
                srcDirOf = p: srcDirs.${p};
              };
            in
            {
              inherit steps;
              applications = pointyLib.evalApplications { stepDefs = defs; inherit metas; };
              subjectBindings = pointyLib.evalSubjectBindings { stepDefs = defs; inherit metas steps; };
            }
          ) stepIdSet;

          certificates = builtins.mapAttrs (
            id: _:
            certify {
              applications = scopes.${id}.applications;
              application = scopes.${id}.applications.${id} // { key = id; };
              output = scopes.${id}.steps.${id};
              subjects = scopes.${id}.subjectBindings id;
              parents = builtins.listToAttrs (
                map (p: {
                  name = p;
                  value = certificates.${p};
                }) (producersOf id)
              );
            }
          ) stepIdSet;

          publishedSteps = builtins.mapAttrs (
            id: _:
            scopes.${id}.steps.${id}
            // {
              def = allStepDefs.${id};
              key = keys.${id};
              certificate = certificates.${id}.certificate;
              dependencies = dependencies.${id};
            }
            // lib.optionalAttrs srcDirs.${id}.hasSrcDir { srcFiles = srcDirs.${id}.srcDir; }
          ) stepIdSet;

          allSteps = pointyLib.evalSteps {
            stepDefs = allStepDefs;
            inherit templates pkgs metas;
            srcDirOf = p: srcDirs.${p};
          };
        in
        {
          config = {
            flake.pointy = {
              schemaVersion = 1;
              stepConfig = pointyLib.renderStepConfig { inherit templates metas; };
              presets = pointyLib.evalPresets { inherit templates presets; };
              steps = publishedSteps;
              projects = pointyLib.evalProjects {
                inherit projects templates presets;
                stepDefs = allStepDefs;
              };
              autocomplete = pointyLib.evalAutocomplete { inherit templates pkgs; };
            };

            perSystem =
              { ... }:
              {
                checks.pointy-applications = applicationsCheck {
                  applications = pointyLib.evalApplications {
                    stepDefs = allStepDefs;
                    inherit metas;
                  };
                  steps = allSteps;
                };
              };
          };
        };
    };
}
