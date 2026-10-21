{ ... }:
let
  arityOf =
    shape:
    {
      subject = "one";
      array = { subject = "many"; }.${shape.element.kind or "data"} or null;
    }
    .${shape.kind or "data"} or null;
in
{
  templateMeta =
    { templates, interfaces }:
    builtins.mapAttrs (
      name: template:
      let
        contract = template.contract or (throw "pointy.template `${name}': contract missing");
        interface = contract.interface or (throw "pointy.template `${name}': contract.interface missing");
        iface = interfaces.${interface} or (throw "pointy.template `${name}': interface `${interface}' is not declared by the core schema");
        kind = template.pointy.type;
        specialArgs =
          if kind ? fileUpload then
            [ "uploaded" ]
          else if kind ? download then
            [ "downloaded" ]
          else
            [ ];

        params = builtins.map (
          sp:
          assert
            !(sp ? error)
            || throw "pointy.template `${name}': the core schema reports `${sp.error}' for interface `${interface}' parameter `${sp.parameter or "?"}'";
          let
            shape = sp.shape or null;
          in
          {
            param = sp.parameter or (throw "pointy core schema: interface `${interface}' has a parameter without a name");
            arity = arityOf shape;
            inherit shape;
            default = sp.default or null;
            required = sp.required or true;
          }
        ) (iface.parameters or [ ]);
        paramNames = builtins.map (p: p.param) params;
        subjectParams = builtins.filter (p: p.arity != null) params;
      in
      {
        inherit interface params subjectParams;
        defaults = builtins.listToAttrs (
          builtins.map (p: {
            name = p.param;
            value = p.default;
          }) (builtins.filter (p: p.default != null) params)
        );
        knownArgs = paramNames ++ specialArgs;
        requiredArgs =
          builtins.map (p: p.param) (
            builtins.filter (p: p.required && p.arity != "many") params
          )
          ++ specialArgs;
      }
    ) templates;
}
