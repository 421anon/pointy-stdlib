{ nixpkgs, ... }:
{
  copyPaths =
    { src, paths }:
    let
      ancestors =
        path:
        let
          parts = nixpkgs.lib.splitString "/" path;
        in
        nixpkgs.lib.genList (i: nixpkgs.lib.concatStringsSep "/" (nixpkgs.lib.take (i + 1) parts)) (
          builtins.length parts
        );
      included = builtins.concatMap ancestors paths;
      relative =
        path: nixpkgs.lib.removePrefix (toString src + "/") (toString path);
    in
    builtins.path {
      path = src;
      name = "pointy-src";
      filter =
        path: _:
          path == src
          || builtins.elem (relative path) included
          || builtins.any (p: nixpkgs.lib.hasPrefix (p + "/") (relative path)) included;
    };

  loadDir =
    dir:
    builtins.readDir dir
    |> nixpkgs.lib.mapAttrs' (
      name: _: {
        name = nixpkgs.lib.removeSuffix ".nix" name;
        value = import (dir + "/${name}");
      }
    );
}
