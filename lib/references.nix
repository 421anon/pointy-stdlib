{ nixpkgs, ... }:
let
  stepIdFromRef = stepRef: builtins.toString stepRef.step;
in
{
  inherit stepIdFromRef;

  subjectRefs =
    args: p:
    if p.arity == "one" then
      nixpkgs.lib.optionals (args ? ${p.param}) [ (stepIdFromRef args.${p.param}) ]
    else
      builtins.map stepIdFromRef (nixpkgs.lib.toList (args.${p.param} or [ ]));
}
