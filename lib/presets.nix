{ nixpkgs, ... }:
{
  evalPresets =
    { templates, presets }:
    builtins.mapAttrs (
      name: preset:
      let
        unknown = builtins.filter (t: !(templates ? ${t})) preset.templates;
      in
      if unknown != [ ] then
        throw "Preset `${name}` references unknown templates: ${nixpkgs.lib.concatStringsSep ", " unknown}."
      else
        preset
        // {
          description = preset.description or null;
          sortKey = preset.sortKey or null;
        }
    ) presets;
}
