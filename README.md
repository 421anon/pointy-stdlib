# pointy-stdlib

Nix flake library that turns a user repository into the flake outputs that [Pointy Notebook](https://github.com/421anon/pointy) consumes.

`pointy-stdlib.lib.mkFlake` wires together step templates, step instances, projects, and source files under `./templates`, `./steps`, `./projects`, and `./srcFiles`, and exposes them as:

- `#pointy.stepConfig` — host-generated per-template UI descriptors: the pure merge of the CORE argument schema (built by `pointy check --schema` over the host's own sources) with the host's optional presentation overrides (`bindings`). The core is the source of shape, finite domain, default, and requiredness; `bindings` contribute presentation (widgets, dropdowns, reference types, labels). Evaluation fails on a binding that names no core parameter, a builder argument that collides with one, an `allowedTypes` value that names no template, or a presentation override the core shape rejects. `nix eval --json '.#pointy.stepConfig'` yields the document the backend serves.
- `#pointy.contractSchema` — the host's core argument schema derivation (a build input; realized at eval by user-authorized IFD).
- `#pointy.checked` / `#pointy.certificates` — per-record semantic results, keyed by record id; records the raw pipeline rejects are omitted here and listed in `#pointy.unresolvable`
- `#pointy.transport` — the canonical applications document, the enrolled module map, and the assembled entry-source tree
- `#pointy.contractModel` — the shared contract model over the entry sources
- `#pointy.stepDefs` — step instance definitions
- `#pointy.projects` — project membership and ordering
- `#pointy.srcFiles` — per-step source files
- `#pointy.dependencies` — step dependency graph, derived from the core schema's parameter kinds
- per-system `#pointy.steps.<id>` and `#pointy.projectOutPaths` — buildable derivations

The core authority carries into record keying: step records and every
host-side argument map (`knownArgs`, resolution, dependencies,
semantic handles/conformance, and the template `compile` args) are keyed
by the core schema's `parameter` name.  Templates declare only
`contract.interface` (and optionally `contract.output`, which defaults
to `"out"`); parameter names, order, kinds, shapes, defaults, and
requiredness come from `#pointy.contractSchema`.

## Host configuration

`mkFlake` always imports the semantic module, so a host supplies the language contract layer:

```nix
pointyLib.mkFlake { inherit inputs; } ({ ... }: {
  pointy = {
    stepDefs = pointyLib.loadDir ./steps;
    templates = pointyLib.loadDir ./templates;
    presets = pointyLib.loadDir ./presets;
    projects = pointyLib.loadDir ./projects;
    srcFiles = ./srcFiles;

    semantic = {
      pkgs = pkgs;            # required: builds the raw steps and sources
      source = ./main.pointy; # required: the entry program
      # language = ...;       # optional: defaults to this stdlib's pointy-lang input
      # modules.csv = "ext/csv.pointy";  # optional; csv is pre-enrolled
      # scanners.csv = { };              # optional; the csv bundle is pre-enrolled
    };
  };
});
```

`semantic.language` must expose `lib.<system>`, `packages.<system>.pointy`, and `pointyScanners.<system>`; `semantic.modules` maps logical module names to source-relative import paths and sources each interface from the same-named scanner bundle.

## Library API

`pointy-stdlib.lib` is the host-facing surface only: `mkFlake`, `loadDir`, and the template extras helpers `csvExtras` and `fastqExtras`. Everything else in the library is implementation. The pointy language flake stays exposed as `pointy-stdlib.language` (and `pointy.semantic.language`), so its interleaved-construction bindings remain reachable even though the standard host path uses sidecars.

See [Setting Up the User Repository](https://github.com/421anon/pointy/blob/main/docs/pages/user-repo-setup.md) for a minimal `flake.nix` and template examples.
