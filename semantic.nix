{ pointyLib, pointy-lang }:
{ cfg, pkgs, source }:
let
  # mkFlake fixes the system list.
  system = "x86_64-linux";
  lang = pointy-lang.lib.forSystem { inherit system pkgs; };
  schema = lang.argumentSchema {
    entry = source;
    extensions = pointy-lang.pointyExtensions.${system};
  };
  metas = pointyLib.templateMeta {
    inherit (cfg) templates;
    schema = schema.document;
  };
  steps = pointyLib.evalSteps (cfg // { inherit pkgs metas; });
in
{
  inherit metas steps;
}
