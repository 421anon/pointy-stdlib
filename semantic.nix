{ pointyLib, pointy-lang }:
{ cfg, stepDefs, pkgs, source }:
let
  system = "x86_64-linux";
  lang = pointy-lang.lib.forSystem { inherit system pkgs; };
  extensions = pointy-lang.pointyExtensions.${system};
  document = lang.schema { entry = source; inherit extensions; };
  interfaces = (lang.readSchema document).interfaces;
  metas = pointyLib.templateMeta { inherit (cfg) templates; inherit interfaces; };
  kernel = cfg // { inherit pkgs metas stepDefs; };
  steps = pointyLib.evalSteps kernel;
  applications = pointyLib.evalApplications (kernel // { inherit steps; });
  subjectBindings = pointyLib.evalSubjectBindings (kernel // { inherit steps; });
  producersOf = entry:
    pkgs.lib.unique (builtins.map (edge: edge.subject) entry.subjectEdges);
  certify = lang.certifier { entry = source; inherit extensions; };
  certificates = builtins.mapAttrs (
    id: entry:
    certify {
      inherit applications;
      application = entry // { key = id; };
      output = steps.${id};
      subjects = subjectBindings id;
      parents = builtins.listToAttrs (builtins.map (key: {
        name = key;
        value = certificates.${key};
      }) (producersOf entry));
    }
  ) applications;
in
{
  inherit metas steps certificates;

  applicationsCheck = lang.applicationsCheck {
    entry = source;
    inherit extensions;
    applications = pkgs.lib.filterAttrs (id: _: (builtins.tryEval steps.${id}.outPath).success) applications;
  };
}
