# pointy-stdlib

Nix flake library that turns a user repository into the flake outputs that [Pointy Notebook](https://github.com/421anon/pointy) consumes.

`pointy-stdlib.lib.mkFlake` wires together step templates, step instances, projects, and source files under `./templates`, `./steps`, `./projects`, and `./srcFiles`:

```nix
pointyLib.mkFlake { inherit inputs; } ({ inputs, ... }: {
  pointy = {
    stepDefs = pointyLib.loadDir ./steps;
    templates = pointyLib.loadDir ./templates;
    presets = pointyLib.loadDir ./presets;
    projects = pointyLib.loadDir ./projects;
    srcFiles = ./srcFiles;

    semantic = {
      # One pkgs for raw steps, entry sources, and certificates.
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      source = ./main.pointy;
      # language = ...;                  # defaults to this stdlib's pointy-lang input
      # modules.csv = "ext/csv.pointy";  # csv is pre-enrolled
      # scanners.csv = { };              # csv is pre-enrolled
    };
  };
});
```

`semantic.language` must expose `lib.<system>`, `packages.<system>.pointy`, and `pointyScanners.<system>`. `modules` maps logical module names to source-relative import paths; each interface is sourced from the same-named scanner bundle.

## Flake outputs

- `#pointy.stepConfig` — per-template UI descriptors: the pure merge of the core argument schema (built by `pointy-certify --mode schema` over the host's own sources) with the host's presentation `bindings`. The core owns names, order, kinds, shapes, defaults, and requiredness; bindings own widgets, dropdowns, and labels. Evaluation fails on a binding that names no core parameter, an `allowedTypes` value that names no template, or a presentation override the core shape rejects. `nix eval --json '.#pointy.stepConfig'` yields the document the backend serves.
- `#pointy.contractSchema` — the schema derivation (IFD at eval); `#pointy.contractModel` — the shared model over the entry sources.
- `#pointy.checked` / `#pointy.certificates` — per record id: the certificate target (`pointy build` / `pointy verify` input) and the certificate.
- `#pointy.unresolvable` — ids the raw pipeline rejects; they are absent from `checked` and `certificates`.
- `#pointy.transport` — the canonical applications document, the enrolled module map, and the assembled entry-source tree.
- `#pointy.stepDefs` / `#pointy.projects` / `#pointy.srcFiles` / `#pointy.dependencies`.
- per-system `packages.pointy.steps` / `projectOutPaths` / `autocomplete`.

Records and every host-side argument map are keyed by the core schema's `parameter` name. Templates declare `contract.interface` (and optionally `contract.output`, default `"out"`) plus presentation `bindings`; `compile` receives the resolved args.

`pointy-stdlib.lib` is the host-facing surface: `mkFlake`, `loadDir`, `csvExtras`, `fastqExtras`.

See [Setting Up the User Repository](https://github.com/421anon/pointy/blob/main/docs/pages/user-repo-setup.md) for a minimal `flake.nix` and template examples.
