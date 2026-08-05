# pointy-stdlib

Nix flake library that turns a user repository into the flake outputs that [Pointy Notebook](https://github.com/421anon/pointy) consumes.

`pointy-stdlib.lib.mkFlake` wires together step templates, step instances, projects, and source files under `./templates`, `./steps`, `./projects`, and `./srcFiles`, and exposes them as:

- `#pointy.stepConfig` — template option schema used by the frontend
- `#pointy.stepDefs` — step instance definitions
- `#pointy.projects` — project membership and ordering
- `#pointy.srcFiles` — per-step source files
- `#pointy.dependencies` — step dependency graph
- `#pointy.deps` — declared pointy repository dependencies:
  `{ namespace = { input, repo? }; }`
- `#pointy.namespaces.<ns>` — each declared dependency's full pointy surface
  mounted under a namespace: its stepDefs, stepConfig, templates, projects,
  presets, srcFiles and deps, plus (resolved from the per-system package view)
  its built `steps`, `projectOutPaths` and `autocomplete`. The namespace root
  is a clean attrset (no fakeDrv markers).
- per-system `#pointy.steps.<id>` and `#pointy.projectOutPaths` — buildable derivations

## Depending on another pointy repo

A repo imports another pointy user repo as a dependency by declaring a flake
input and listing it in `pointy.deps`:

```nix
{
  # repo B's flake
  inputs = {
    a.url = "git@example.com:org/edit-tooling.git"; # A's flake (a pointy repo)
    pointy-stdlib.url = "github:421anon/pointy-stdlib";
  };
  outputs = { pointy-stdlib, ... }@inputs:
    pointy-stdlib.lib.mkFlake { inherit inputs; } {
      pointy = {
        # ... own stepDefs/templates/projects/srcFiles ...
        deps = {
          edit-tooling = { input = "a"; repo = "edit-tooling"; };
        };
      };
    };
}
```

- `input` must name a flake input of this repo (never `self`); `repo`
  (optional) is the dependency's pointy registry name and defaults to
  resolving the input's locked URL against the registry.
- Because `packages.<system>.pointy` shadows the top-level `pointy` output for
  installable resolution, `#pointy.namespaces.<ns>` resolves to the per-system
  merged surface, so both of these reach the dependency's built steps:
  - `#pointy.namespaces.edit-tooling.steps.<id>` (docs-friendly form)
  - `#packages.<system>.pointy.namespaces.edit-tooling.steps.<id>` (explicit)
  and `#pointy.namespaces.edit-tooling.stepDefs` etc. reach its domain objects.
- `#pointy.deps` is pure metadata of B's own committed state: evaluating it
  does not force evaluation of dependency content.
- Unknown / non-pointy / `self` inputs fail with a descriptive error when the
  namespace is forced.

In the single-repo backend variant the dependency resolves from the
committed flake.lock at evaluation time, exactly like any other flake input.

See [Setting Up the User Repository](https://github.com/421anon/pointy/blob/main/docs/pages/user-repo-setup.md) for a minimal `flake.nix` and template examples.
