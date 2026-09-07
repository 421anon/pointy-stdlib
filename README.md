# pointy-stdlib

Nix flake library that turns a user repository into the flake outputs that [Pointy Notebook](https://github.com/421anon/pointy) consumes.

`pointy-stdlib.lib.mkFlake` wires together step templates, step instances, projects, and source files under `./templates`, `./steps`, `./projects`, and `./srcFiles`, and exposes them as:

- `#pointy.stepConfig` — host-generated per-template UI descriptors: a realized derivation merging the CORE argument schema (built by `pointy check --schema` over the host's own sources) with the host's optional presentation overrides (`bindings`). The core is the source of shape, finite domain, default, and requiredness; `bindings` contribute presentation (widgets, dropdowns, reference types, labels); unknown override names reject. The backend serves the realized JSON.
- `#pointy.contractSchema` — the host's core argument schema derivation (a build input; realized at eval by user-authorized IFD).
- `#pointy.stepDefs` — step instance definitions
- `#pointy.projects` — project membership and ordering
- `#pointy.srcFiles` — per-step source files
- `#pointy.dependencies` — step dependency graph, derived from the declared contract kinds
- per-system `#pointy.steps.<id>` and `#pointy.projectOutPaths` — buildable derivations

The core authority carries into record keying: step records and every
adapter-side argument map (`knownArgs`, resolution, dependencies,
semantic handles/conformance, and the template `compile` args) are keyed
by the contract's `param`. `contract.parameters` entries carry `param`
(and optional `kind`).

See [Setting Up the User Repository](https://github.com/421anon/pointy/blob/main/docs/pages/user-repo-setup.md) for a minimal `flake.nix` and template examples.
