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

`semantic` takes the two things the library cannot decide: the entry program and the one `pkgs` the compiler, the raw steps, and the entry sources share. The language integration is this stdlib's own opinion: this flake's `pointy-lang` input, the extension set that language ships (`pointyExtensions.<system>`, enrolled at the language's import paths), and the one system `mkFlake` fixes.

One `nixpkgs`, and the compiler owns the choice: this flake's `nixpkgs` follows `pointy-lang/nixpkgs`, so the compiler is built with the rev the language's own lock tests against. A host that wants the library and its raw steps on its own nixpkgs sets `pointy-stdlib.inputs.nixpkgs.follows = "nixpkgs"` (the compiler keeps the language's pin unless the host also follows into `pointy-lang`).

The argument-schema document is built from `semantic.source` with the compiler and read back through `readSchema`, which validates its format and version before any interface is used; an invalid source fails evaluation with the compiler's own located diagnostic. Every interface names its canonical output type expression and every parameter carries one recursive `shape`, whose leaves are either wire data or an artifact (`subject`) position — a producer parameter is a `subject` leaf, and an ordered family of producers is an array of `subject` leaves — so no data type's identity reaches the host vocabulary. A subject leaf also carries the type expression it stands for and `accepts`: every interface in the program whose output meets that type, each with the verdict unification produced (`subsumed`, or `residual` for the part that only a build-time certificate can discharge). `templateMeta` merges the document with the host's `bindings`, and `evalSteps` builds the raw steps against its parameter table.

## Flake outputs

- `#pointy.stepConfig` — the notebook's form document (`{ version = 4; templates = …; }`): every parameter becomes a field carrying the core's own facts (order, name, `required`, `default`) plus one control (`widget`) and one value shape (`shape`), so the notebook renders forms without per-template code. The core owns names, order, shapes, defaults and requiredness; bindings own widgets, labels and `quickCreate`. A subject shape carries `accepts` and `proven` — the step types whose interfaces the core's unification admits, and the subsumed subset it proves outright — so a producer dropdown offers exactly what meets the consumer's parameter. A template declares only what differs; the widget vocabulary is closed (`text`, `textarea`, `code`, `command`, `number`, `checkbox`, `select`, `tokens`, `list`, `step`, `steps`, `record`, `datetime`) and evaluation fails on a binding that names no core parameter, a presentation override the shape cannot express, an unknown widget, or a widget missing its parameter. `nix eval --json '.#pointy.stepConfig'` yields the document the backend serves.
- `#pointy.stepDefs` / `#pointy.projects` / `#pointy.srcFiles` / `#pointy.dependencies`.
- `#pointy.steps` — the raw buildables.
- `#pointy.projectOutPaths` / `#pointy.projectCertificates` — per project, the step `outPath` and the step certificate output path, `/invalid` where evaluation fails, so the notebook resolves one project per evaluation.
- `#pointy.autocomplete` — the template autocomplete hooks.
- `#pointy.certificates.<id>` — one certificate per step whose `outPath` evaluates: `{ model, certificate, target }`, built from the same applications document the check runs over, with `output = steps.<id>` and the certificates of the step's own producers as `parents`. The `certificate` derivation has two outputs: `out` is the canonical certificate, `target` the target descriptor of that same run (the path `pointy verify --against` replays against, with `--certificate-drv` naming the derivation). The certificate checks the step's own output against its interface's declared output type and discharges its incoming residuals against its producers' certificates, exporting the facts it observed (including the selected `|` branch per join-typed parameter); a step's certificate succeeding means its output and its whole upstream closure are certified. The schema document is read at evaluation; forcing those exports is the flow's other import-from-derivation.
- `#checks.<system>.pointy-applications` — `pointy check --applications` over every step record: interface from the template contract, arguments with producers in the acquisition envelope, optional `refine` per step. It fails on a `Bottom` edge, never on a residual.

Each output above is read by the notebook backend; anything it does not read is not published.

Records and every host-side argument map are keyed by the core schema's `parameter` name. Templates declare `contract.interface` plus presentation `bindings`; `compile` receives the resolved args. A binding nests one level per shape layer: a list's knobs live under `list`, a record's under `record` (its fields under `record.fields.<name>`), and `quickCreate` sits on the subject leaf itself. A step record may carry a top-level `refine = "<type expression>"`; it is part of the step's declared output type for applications and certificates, and never reaches the step derivation.

The step envelope is the library's, not the template's: `compile { lib, pkgs, pointyLib }` returns `{ build = { args, public }: { name?; version?; env?; mkDerivation; }; }`, and `evalSteps` supplies the `pname` (the step's type unless the template names one), `version = "1"`, the `trotterPackage` marker and the metadata every step carries (`meta.pointy.id`/`type`/`requirements`/`args`). A template declares only what makes it different: `requirements` as an attrset — or a function of the resolved args — merged over `{ ram = "1G"; cpu = 1; ior = "0"; iow = "0"; }`, and `extras = "csv"` or `"fastq"` to have the matching artifact scan attached to its metadata. `nixDepPkgs` resolves `nixDeps` names against the one `pkgs`; `stepLinkCommands` links step dependencies into a build directory under their step ids.

`pointy-stdlib.lib` is the host-facing surface: `mkFlake`, `loadDir`, `csvExtras`, `fastqExtras`, `nixDepPkgs`, `stepLinkCommands`.

See [Setting Up the User Repository](https://github.com/421anon/pointy/blob/main/docs/pages/user-repo-setup.md) for a minimal `flake.nix` and template examples.
