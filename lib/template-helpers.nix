{ nixpkgs, ... }:
{
  nixDepPkgs =
    { pkgs, nixDeps }:
    map (
      name:
      let
        path = nixpkgs.lib.splitString "." name;
      in
      assert nixpkgs.lib.assertMsg (nixpkgs.lib.hasAttrByPath path pkgs) "Unknown Nix package `${name}`.";
      nixpkgs.lib.getAttrFromPath path pkgs
    ) nixDeps;

  stepLinkCommands =
    { stepDeps }:
    builtins.concatStringsSep "\n" (map (depPkg: "ln -s ${depPkg} ./${depPkg.meta.pointy.id}") stepDeps);

  csvExtras =
    {
      pkgs,
      baseDrv,
      requirements ? {
        ram = "2G";
        cpu = 2;
        ior = "0";
        iow = "0";
      },
    }:
    pkgs.runCommand "csv-extras" { } ''
      bash ${./csv-extras.sh} \
        ${pkgs.duckdb}/bin/duckdb \
        ${pkgs.jq}/bin/jq \
        "${baseDrv}" \
        "$out"
    ''
    // { inherit requirements; };

  fastqExtras =
    {
      pkgs,
      baseDrv,
      requirements ? {
        ram = "1G";
        cpu = 1;
        ior = "0";
        iow = "0";
      },
    }:
    pkgs.runCommand "fastq-extras" { } ''
      bash ${./fastq-extras.sh} \
        "${baseDrv}" \
        "$out"
    ''
    // { inherit requirements; };
}
