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
      pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      source = ./main.pointy;
    };
  };
});
```

`semantic` takes the two things the library cannot decide: the entry program, and the one `pkgs` the compiler, the raw steps, and the entry sources share. The language integration is this stdlib's own opinion: this flake's `pointy-lang` input, the extension set that language ships (`pointyExtensions.<system>`, enrolled at the language's import paths), and the one system `mkFlake` fixes.

One `nixpkgs`, and the compiler owns the choice: this flake's `nixpkgs` follows `pointy-lang/nixpkgs`, so the compiler is built with the rev the language's own lock tests against. A host that wants the library and its raw steps on its own nixpkgs sets `pointy-stdlib.inputs.nixpkgs.follows = "nixpkgs"` (the compiler keeps the language's pin unless the host also follows into `pointy-lang`).

The language integration is the compiler's `argumentSchema`: the library hands over the program and its extension sources, and the language builds the import layout, runs the core's source pass (`pointy-certify --mode schema`, IFD at eval — an invalid source fails evaluation with the core's located diagnostic) and returns the parsed document. The document is argument-schema version 3: every parameter carries one recursive `shape`, whose leaves are either wire data or an artifact (`subject`) position — a producer parameter is a `subject` leaf, and an ordered family of producers is an array of `subject` leaves — so no data type's identity reaches the host vocabulary. `templateMeta` merges that document with the host's `bindings`, and `evalSteps` builds the raw steps against its parameter table. Per-record certification is out of scope: nothing in the library builds a certificate derivation.

## Flake outputs

- `#pointy.stepConfig` — per-template UI descriptors: the pure merge of the core argument schema (built by `pointy-certify --mode schema` over the host's own sources) with the host's presentation `bindings`. The core owns names, order, shapes, defaults, and requiredness; bindings own widgets, dropdowns, and labels. Evaluation fails on a binding that names no core parameter, an `allowedTypes` value that names no template, or a presentation override the core shape rejects. `nix eval --json '.#pointy.stepConfig'` yields the document the backend serves.
- `#pointy.stepDefs` / `#pointy.projects` / `#pointy.srcFiles` / `#pointy.dependencies`.
- `#pointy.steps` / `#pointy.projectOutPaths` / `#pointy.autocomplete` — the raw buildables, the per-project output paths, and the template autocomplete hooks.

Each output above is read by the notebook backend; anything it does not read is not published.

Records and every host-side argument map are keyed by the core schema's `parameter` name. Templates declare `contract.interface` (and optionally `contract.output`, default `"out"`) plus presentation `bindings`; `compile` receives the resolved args. A binding nests one level per shape layer: a list's knobs live under `list`, a record's under `record` (its fields under `record.fields.<name>`), and `allowedTypes`/`quickCreate` sit on the subject leaf itself.

`pointy-stdlib.lib` is the host-facing surface: `mkFlake`, `loadDir`, `csvExtras`, `fastqExtras`.

See [Setting Up the User Repository](https://github.com/421anon/pointy/blob/main/docs/pages/user-repo-setup.md) for a minimal `flake.nix` and template examples.
