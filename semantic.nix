{ pointyLib, pointy-lang }:
{ cfg, stepDefs, pkgs, source, schema, schemaRel }:
let
  system = "x86_64-linux";
  lang = pointy-lang.lib.forSystem { inherit system pkgs; };
  extensions = pointy-lang.pointyExtensions.${system};
  interfaces = (lang.readSchema schema).interfaces;
  metas = pointyLib.templateMeta { inherit (cfg) templates; inherit interfaces; };
  kernel = cfg // { inherit pkgs metas stepDefs; };
  steps = pointyLib.evalSteps kernel;
  applications = pointyLib.evalApplications (kernel // { inherit steps; });
  subjectBindings = pointyLib.evalSubjectBindings (kernel // { inherit steps; });
  regenerated = lang.schema { entry = source; inherit extensions; };
  producersOf = entry:
    pkgs.lib.unique (builtins.map (edge: edge.subject) entry.subjectEdges);
  certificates = builtins.mapAttrs (
    id: entry:
    lang.certificate {
      entry = source;
      inherit extensions applications;
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

  schemaDrift = pkgs.runCommand "pointy-schema-check" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
    if ! cmp -s ${regenerated} ${schema}; then
      echo "pointy: ${schemaRel} is stale; regenerate it with nix run .#pointy-schema" >&2
      diff -u ${schema} ${regenerated} >&2 || true
      exit 1
    fi
    touch $out
  '';

  schemaWriter = pkgs.writeShellApplication {
    name = "pointy-schema";
    runtimeInputs = [ pkgs.coreutils pkgs.git ];
    text = ''
      root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
      install -Dm644 ${regenerated} "$root/${schemaRel}"
    '';
  };

  applicationsCheck = lang.applicationsCheck {
    entry = source;
    inherit extensions applications;
  };
}
