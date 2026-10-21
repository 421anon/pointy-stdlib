{ nixpkgs, pointyLib, ... }:
{
  evalLinkedData =
    {
      stepDefs,
      templates,
      metas,
      folders,
      rev,
      steps,
      publishedSteps,
    }:
    let
      inherit (pointyLib) turtle;

      stepIds = builtins.attrNames stepDefs;
      defOf = id: stepDefs.${id};
      metaOf = id: metas.${(defOf id).type or ""} or { subjectParams = [ ]; };
      kindOf = id: (templates.${(defOf id).type or ""} or { }).pointy.type or { };
      isDerivation = id: kindOf id ? derivation;
      stepIdOf = id: (defOf id).id or (nixpkgs.lib.toIntBase10 id);

      referenceValues =
        args: p:
        if p.arity == "one" then
          nixpkgs.lib.optionals (args ? ${p.param}) [ args.${p.param} ]
        else
          nixpkgs.lib.toList (args.${p.param} or [ ]);

      referencesOf =
        id:
        let
          args = (defOf id).args or { };
        in
        builtins.concatMap (
          p: builtins.map (value: { field = p.param; inherit value; }) (referenceValues args p)
        ) (metaOf id).subjectParams;

      directReferencesOf = id: if isDerivation id then referencesOf id else [ ];

      referenceStep = reference: builtins.toString reference.value.step;
      referenceHasPath = reference: reference.value ? path;
      referencePath = reference: reference.value.path;

      isStale =
        reference:
        if !(referenceHasPath reference) then
          false
        else if !(folders.pathIsValid (referencePath reference)) then
          true
        else
          !(folders.holdsStep (referencePath reference) (referenceStep reference));

      staleOf =
        id:
        builtins.map (reference: {
          step = stepIdOf id;
          inherit reference;
        }) (builtins.filter isStale (referencesOf id));

      staleDependencies = builtins.sort (a: b: a.step < b.step) (
        builtins.map (entry: {
          inherit (entry) step;
          dependency = entry.reference.value;
        }) (builtins.concatMap staleOf stepIds)
      );

      noticesOf =
        id:
        builtins.map (
          reference:
          let dependency = builtins.toString reference.value.step; in
          {
            inherit (reference) field;
            severity = "info";
            message = "Step ${dependency} is not in folder ${folders.folderLabel (referencePath reference)} at this commit; the reference falls back to step ${dependency} wherever it lives.";
          }
        ) (builtins.filter isStale (referencesOf id));

      resolveReference =
        reference:
        let
          step = referenceStep reference;
          recorded = referencePath reference;
          keepRecorded =
            referenceHasPath reference
            && folders.pathIsValid recorded
            && folders.holdsStep recorded step;
        in
        {
          inherit step;
          path = if keepRecorded then recorded else folders.stepPath step;
        };

      nodeKey =
        node: builtins.concatStringsSep "/" (builtins.map builtins.toString node.path) + "/" + node.step;

      childrenOfNode =
        node:
        builtins.map resolveReference (
          builtins.filter (reference: stepDefs ? ${referenceStep reference}) (directReferencesOf node.step)
        );

      collect =
        start:
        let
          go =
            queue: seen: acc:
            if queue == [ ] then
              acc
            else
              let
                node = builtins.head queue;
                key = nodeKey node;
                rest = builtins.tail queue;
              in
              if seen ? ${key} then
                go rest seen acc
              else
                go (rest ++ childrenOfNode node) (seen // { ${key} = true; }) (acc ++ [ node ]);
        in
        go [ start ] { } [ ];

      pathLess =
        left: right:
        if left == [ ] then
          right != [ ]
        else if right == [ ] then
          false
        else
          builtins.head left < builtins.head right
          || (builtins.head left == builtins.head right && pathLess (builtins.tail left) (builtins.tail right));

      nodeLess =
        left: right:
        stepIdOf left.step < stepIdOf right.step
        || (stepIdOf left.step == stepIdOf right.step && pathLess left.path right.path);

      revision =
        if rev == null then throw "pointy: linked data needs a committed revision" else builtins.toString rev;

      iriOf =
        node:
        "/artifact/"
        + builtins.concatStringsSep "/" (builtins.map builtins.toString (node.path ++ [ node.step ]))
        + "/"
        + revision;

      isLinkable =
        value:
        builtins.isString value
        && builtins.match ("https?:[^ <>\"{}|^`\\\\" + turtle.controlCharacters + "]+") value != null;

      uniqueInOrder =
        values:
        builtins.foldl' (acc: value: if builtins.elem value acc then acc else acc ++ [ value ]) [ ] values;

      aboutOf =
        id:
        let about = (defOf id).about or [ ]; in
        uniqueInOrder (builtins.filter isLinkable (if builtins.isList about then about else [ ]));

      describe =
        node:
        let
          def = defOf node.step;
          nodeIri = iriOf node;
          name = def.name or "";
          label =
            if builtins.isString name && nixpkgs.lib.trim name != "" then name else node.step;
          template = def.type or "";
          output = builtins.tryEval (steps.${node.step}.outPath);
          derivedIris = uniqueInOrder (
            builtins.sort (a: b: a < b) (
              builtins.filter (iri: iri != nodeIri) (
                builtins.map (
                  reference: iriOf (resolveReference reference)
                ) (
                  builtins.filter (reference: stepDefs ? ${referenceStep reference}) (
                    directReferencesOf node.step
                  )
                )
              )
            )
          );
          about = aboutOf node.step;
          clauses =
            [
              {
                predicate = "a";
                objects = [ "prov:Entity" ];
              }
              {
                predicate = "rdfs:label";
                objects = [ (turtle.literal label) ];
              }
            ]
            ++ nixpkgs.lib.optional (builtins.isString template && template != "") {
              predicate = "pointy:template";
              objects = [ (turtle.literal template) ];
            }
            ++ nixpkgs.lib.optional output.success {
              predicate = "pointy:output";
              objects = [ (turtle.literal output.value) ];
            }
            ++ nixpkgs.lib.optional (derivedIris != [ ]) {
              predicate = "prov:wasDerivedFrom";
              objects = builtins.map turtle.iri derivedIris;
            }
            ++ nixpkgs.lib.optional (about != [ ]) {
              predicate = "schema:about";
              objects = builtins.map turtle.iri about;
            };
        in
        {
          iri = nodeIri;
          inherit clauses;
        };

      orderedNodes =
        start:
        [
          start
        ]
        ++ builtins.sort nodeLess (
          builtins.filter (node: nodeKey node != nodeKey start) (collect start)
        );

      subjectsFor =
        path: stepId:
        builtins.map describe (orderedNodes {
          inherit path;
          step = builtins.toString stepId;
        });

      documentOf =
        subjects:
        builtins.unsafeDiscardStringContext (
          turtle.document {
            prefixes = [
              (turtle.prefix "prov" "http://www.w3.org/ns/prov#")
              (turtle.prefix "rdfs" "http://www.w3.org/2000/01/rdf-schema#")
              (turtle.prefix "schema" "https://schema.org/")
              (turtle.prefix "pointy" "https://pointy.cloud/ns#")
            ];
            inherit subjects;
          }
        );

      isPercentEncoded = query: builtins.match "[A-Za-z0-9%._~!*'()-]+" query != null;

      fileDocumentOf =
        subjects:
        { path, query }:
        let
          output = builtins.head subjects;
          fileIri =
            if isPercentEncoded query then
              output.iri + "?path=" + query
            else
              throw "pointy: the file query `${query}' is not percent-encoded";
          file = {
            iri = fileIri;
            clauses = [
              {
                predicate = "a";
                objects = [ "prov:Entity" ];
              }
              {
                predicate = "rdfs:label";
                objects = [ (turtle.literal (nixpkgs.lib.last (nixpkgs.lib.splitString "/" path))) ];
              }
            ];
          };
          collection = output // {
            clauses = output.clauses ++ [
              {
                predicate = "prov:hadMember";
                objects = [ (turtle.iri fileIri) ];
              }
            ];
          };
        in
        documentOf ([ file collection ] ++ builtins.tail subjects);

      notifiedSteps = builtins.mapAttrs (
        id: step:
        step
        // {
          meta = (step.meta or { }) // {
            pointy = (step.meta.pointy or { }) // {
              notices = (step.meta.pointy.notices or [ ]) ++ noticesOf id;
            };
          };
        }
      ) publishedSteps;

      folderNode =
        path: pid:
        let
          folderPath = if pid == "0" then [ ] else path ++ [ (folders.projectId pid) ];
          children = folders.effectiveChildren pid;
        in
        {
          steps = builtins.listToAttrs (
            builtins.map (
              child:
              let
                id = builtins.toString child.step.id;
                subjects = subjectsFor folderPath id;
              in
              {
                name = id;
                value = notifiedSteps.${id} // {
                  turtle = documentOf subjects;
                  fileTurtle = fileDocumentOf subjects;
                };
              }
            ) (builtins.filter (child: child ? step) children)
          );
        }
        // builtins.listToAttrs (
          builtins.map (
            child:
            let id = builtins.toString child.project.id; in
            {
              name = id;
              value = folderNode folderPath id;
            }
          ) (builtins.filter (child: !(child ? step)) children)
        );

      root = folderNode [ ] "0";
    in
    {
      inherit staleDependencies;
      steps = notifiedSteps;
      inherit root;
    };
}
