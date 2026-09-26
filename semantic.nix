{ pointyLib, pointy-lang }:
{ pkgs, source, templates }:
let
  system = "x86_64-linux";
  lang = pointy-lang.lib.forSystem { inherit system pkgs; };
  extensions = pointy-lang.pointyExtensions.${system};
  document = lang.schema { entry = source; inherit extensions; };
  interfaces = (lang.readSchema document).interfaces;
  metas = pointyLib.templateMeta { inherit templates; inherit interfaces; };
  certify = lang.certifier { entry = source; inherit extensions; };
  applicationsCheck =
    { applications, steps }:
    lang.applicationsCheck {
      entry = source;
      inherit extensions;
      applications = pkgs.lib.filterAttrs (id: _: (builtins.tryEval steps.${id}.outPath).success) applications;
    };
in
{
  inherit metas certify applicationsCheck;
}
