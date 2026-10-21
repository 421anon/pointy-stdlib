{ nixpkgs, ... }:
{
  evalProjects =
    {
      projects,
      templates,
      presets ? { },
      stepDefs,
    }:
    builtins.mapAttrs (
      id: proj:
      let
        preset = proj.preset or null;
        declaredTemplates = proj.templates or null;
        hasPreset = preset != null;
        hasTemplates = declaredTemplates != null;
        unknownTemplates =
          if hasTemplates then builtins.filter (t: !(templates ? ${t})) declaredTemplates else [ ];
        isStep = child: child ? step;
        stepIdOf = child: toString child.step.id;
        projectIdOf = child: toString child.project.id;
        isKnown =
          child:
          if isStep child then stepDefs ? ${stepIdOf child} else projects ? ${projectIdOf child};
        unknownChildren = builtins.filter (child: !(isKnown child)) proj.children;
        unknownStepIds = map stepIdOf (builtins.filter isStep unknownChildren);
        unknownProjectIds = map projectIdOf (
          builtins.filter (child: !(isStep child)) unknownChildren
        );
        validationErrors =
          nixpkgs.lib.optional (
            hasPreset && !(presets ? ${preset})
          ) "Unknown preset `${preset}`. Pick another preset in the edit form."
          ++
            nixpkgs.lib.optional (hasTemplates && unknownTemplates != [ ])
              "Unknown templates: ${nixpkgs.lib.concatStringsSep ", " unknownTemplates}. Remove them in the edit form."
          ++ nixpkgs.lib.optional (
            unknownStepIds != [ ]
          ) "Unknown step ids: ${nixpkgs.lib.concatStringsSep ", " unknownStepIds}."
          ++ nixpkgs.lib.optional (
            unknownProjectIds != [ ]
          ) "Unknown project ids: ${nixpkgs.lib.concatStringsSep ", " unknownProjectIds}.";
      in
      if !hasPreset && !hasTemplates then
        throw "Project `${id}` must define either `preset` or `templates`."
      else if hasPreset && hasTemplates then
        throw "Project `${id}` cannot define both `preset` and `templates`."
      else
        proj
        // {
          inherit preset;
          templates = declaredTemplates;
          id = nixpkgs.lib.toIntBase10 id;
          children = map (
            child:
            if isStep child then
              { step = child.step // { def = stepDefs.${stepIdOf child}; }; }
            else
              child
          ) (builtins.filter isKnown proj.children);
          inherit validationErrors;
        }
    ) projects;

  evalProjectFolders =
    { projects }:
    let
      projectsById = builtins.listToAttrs (
        builtins.map (
          key:
          {
            name = builtins.toString projects.${key}.id;
            value = projects.${key};
          }
        ) (builtins.attrNames projects)
      );

      innerOf = child: if child ? step then child.step else child.project;
      isStepChild = child: child ? step;
      refKey = child: (if isStepChild child then "s" else "p") + builtins.toString (innerOf child).id;

      placement =
        child:
        let
          inner = innerOf child;
          sortKey = inner.sortKey or null;
        in
        if builtins.isInt sortKey then
          {
            rank = 0;
            key = sortKey;
            id = inner.id;
          }
        else
          {
            rank = 1;
            key = 0;
            id = inner.id;
          };

      entryLess =
        a: b:
        let
          first = placement a;
          second = placement b;
        in
        first.rank < second.rank
        || (
          first.rank == second.rank
          && (first.key < second.key || (first.key == second.key && first.id < second.id))
        );

      effectiveChildren =
        pid:
        if !(projectsById ? ${pid}) then
          [ ]
        else
          let
            deduped = builtins.foldl' (
              acc: child:
              let key = refKey child; in
              if acc.seen ? ${key} then
                acc
              else
                {
                  seen = acc.seen // { ${key} = true; };
                  out = acc.out ++ [ child ];
                }
            ) { seen = { }; out = [ ]; } (projectsById.${pid}.children or [ ]);
          in
          builtins.sort entryLess deduped.out;

      childFolder =
        pid: childId:
        let
          matches = builtins.filter (
            child:
            !(isStepChild child)
            && builtins.toString (innerOf child).id == builtins.toString childId
          ) (effectiveChildren pid);
        in
        if matches == [ ] then null else builtins.toString (innerOf (builtins.head matches)).id;

      folderAt =
        path:
        builtins.foldl' (
          current: childId:
          if current == null then null else childFolder current childId
        ) (if projectsById ? "0" then "0" else null) path;

      holdsStep =
        path: stepId:
        let pid = folderAt path; in
        pid != null
        && builtins.any (
          child: isStepChild child && builtins.toString (innerOf child).id == builtins.toString stepId
        ) (effectiveChildren pid);

      roots =
        let
          ids = builtins.attrNames projectsById;
          nestedIds = builtins.foldl' (
            acc: pid:
            builtins.foldl' (
              acc2: child:
              if isStepChild child then acc2 else acc2 // { ${builtins.toString (innerOf child).id} = true; }
            ) acc (effectiveChildren pid)
          ) { } ids;
        in
        builtins.sort (
          a: b: projectsById.${a}.id < projectsById.${b}.id
        ) (builtins.filter (pid: !(nestedIds ? ${pid})) ids);

      walk =
        visited: ancestors: pid:
        let
          projectId = projectsById.${pid}.id;
          path = if projectId == 0 then [ ] else ancestors ++ [ projectId ];
          children = effectiveChildren pid;
          here = builtins.map (child: {
            step = builtins.toString (innerOf child).id;
            inherit path;
          }) (builtins.filter isStepChild children);
          visitedHere = visited // { ${pid} = true; };
          nested = builtins.concatMap (
            child:
            if isStepChild child then
              [ ]
            else
              let childPid = builtins.toString (innerOf child).id; in
              if visitedHere ? ${childPid} then [ ] else walk visitedHere path childPid
          ) children;
        in
        here ++ nested;

      stepPaths = builtins.foldl' (
        acc: entry:
        if acc ? ${entry.step} then
          acc
        else
          acc // { ${entry.step} = entry.path; }
      ) { } (builtins.concatMap (walk { } [ ]) roots);

      stepPath = stepId: stepPaths.${builtins.toString stepId} or [ ];

      folderLabel =
        path:
        if path == [ ] then
          "the root folder"
        else if !(builtins.isList path) || !(builtins.all builtins.isInt path) then
          "the recorded folder"
        else
          builtins.concatStringsSep " › " (
            builtins.map (
              projectId:
              let project = projectsById.${builtins.toString projectId} or null; in
              if project == null then builtins.toString projectId else project.name or (builtins.toString projectId)
            ) path
          );
    in
    {
      inherit
        effectiveChildren
        folderAt
        holdsStep
        roots
        stepPath
        folderLabel
        ;
      projectId = pid: projectsById.${pid}.id;
      pathIsValid = path: builtins.isList path && builtins.all builtins.isInt path;
    };
}
