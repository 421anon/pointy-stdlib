{
  self,
  nixpkgs,
  flake-parts,
  ...
}@inputs:
let
  moduleFiles = [
    ./lib/files.nix
    ./lib/template-helpers.nix
    ./lib/references.nix
    ./lib/templates.nix
    ./lib/applications.nix
    ./lib/steps.nix
    ./lib/presets.nix
    ./lib/autocomplete.nix
    ./lib/projects.nix
    ./lib/turtle.nix
    ./lib/linked-data.nix
    ./lib/mk-flake.nix
  ];
  base = {
    renderStepConfig = (import ./lib/step-config.nix { inherit (nixpkgs) lib; }).renderStepConfig;
  };
  merged = builtins.foldl' (
    acc: file:
    acc // import file (inputs // { pointyLib = pointyLib; })
  ) base moduleFiles;
  pointyLib = merged // {
    api = {
      inherit (merged)
        mkFlake
        loadDir
        csvExtras
        fastqExtras
        nixDepPkgs
        stepLinkCommands
        ;
    };
  };
in
pointyLib
