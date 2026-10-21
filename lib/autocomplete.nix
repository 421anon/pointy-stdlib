{ nixpkgs, ... }:
{
  evalAutocomplete =
    { templates, pkgs }:
    builtins.mapAttrs (
      _name: template:
      if template ? autocomplete then
        template.autocomplete {
          inherit pkgs;
          lib = nixpkgs.lib;
        }
      else
        { }
    ) templates;
}
