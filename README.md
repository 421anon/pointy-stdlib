# pointy-stdlib

Nix flake library that turns a user repository into the flake outputs that [Pointy Notebook](https://github.com/421anon/pointy) consumes.

A user repository holds `pointy.nix` beside its `flake.nix`. The `flake.nix` passes its inputs through:

```nix
inputs@{ pointy-stdlib, ... }:
pointy-stdlib.lib.mkFlake { inherit inputs; }
```

`pointy.nix` is imported from the repository's global source copy and returns the two things the library cannot decide:

```nix
{ inputs, ... }:
{
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  source = ./main.pointy;
}
```

`mkFlake` copies `flake.nix`, `pointy.nix`, `templates/`, `packages/` and `main.pointy` into one store path — the global source — and imports `pointy.nix` from that copy, so every relative path a repository configures resolves inside it. The step definitions (`steps/`), the projects, the presets and the step source directories are read from the repository itself, one store path per step.

A repository that needs flake-parts configuration of its own passes it as `modules`:

```nix
inputs@{ pointy-stdlib, ... }:
pointy-stdlib.lib.mkFlake {
  inherit inputs;
  modules = [ { perSystem = { ... }: { packages.example = pointy.pkgs.hello; }; } ];
}
```

The language integration is this stdlib's own opinion: this flake's `pointy-lang` input, the extension set that language ships (`pointyExtensions.<system>`, enrolled at the language's import paths), and the one system `mkFlake` fixes.

One `nixpkgs`, and the compiler owns the choice: this flake's `nixpkgs` follows `pointy-lang/nixpkgs`, so the compiler is built with the rev the language's own lock tests against. A host that wants the library and its raw steps on its own nixpkgs sets `pointy-stdlib.inputs.nixpkgs.follows = "nixpkgs"` (the compiler keeps the language's pin unless the host also follows into `pointy-lang`).

The argument-schema document is built from `source` with the compiler and read back through `readSchema`, which validates its format and version before any interface is used; an invalid source fails evaluation with the compiler's own located diagnostic. Every interface names its canonical output type expression and every parameter carries one recursive `shape`, whose leaves are either wire data or an artifact (`subject`) position — a producer parameter is a `subject` leaf, and an ordered family of producers is an array of `subject` leaves — so no data type's identity reaches the host vocabulary. A subject leaf also carries the type expression it stands for and `accepts`: every interface in the program whose output meets that type, each with the verdict unification produced (`subsumed`, or `residual` for the part that only a build-time certificate can discharge). `templateMeta` merges the document with the host's `bindings`, and `evalSteps` builds the raw steps against its parameter table.

## The step input boundary

A step is evaluated against its own path, the global source path, and the store paths of its producers' step files. Each step file is imported from its own single-file copy, and its source directory is copied on its own, so a step file that reads a sibling or a parent directory fails evaluation instead of picking up content no key accounts for. The referenced producer closure is the only set of step definitions a step sees, so a reference outside it fails rather than evaluating an unrelated step.

`#pointy.steps.<id>.key` is the content address of exactly those inputs: the Nix version, the repository's `flake.lock`, the global source path, the step file path, the step's source directory, and the keys of the producers the step's own definition names, with an absent step recorded as absent. A template, a package, `main.pointy`, `flake.nix` or `flake.lock` change moves the global source path or the lock hash, so it moves every key; a step file or source directory change moves that step's key and the keys of the steps whose closures reach it. A step whose own file fails to import has no key: forcing the attribute throws, and `builtins.tryEval` reports the failure.

A step says what it cannot evaluate: a missing template, a missing producer, or a definition without a type or arguments raises the library's own located error, which `builtins.tryEval` catches. A read that leaves the step's own paths is a pure-evaluation error that ends the enclosing evaluation instead.

## Flake outputs

- `#pointy.schemaVersion` — `1`, the version of the output shape above. A repository whose lock predates it publishes no `schemaVersion`, no `steps.<id>.key` and no `steps.<id>.srcFiles`; the notebook backend detects the missing attribute and evaluates that repository the way it did before this version.
- `#pointy.stepConfig` — the notebook's form document (`{ version = 4; templates = …; }`): every parameter becomes a field carrying the core's own facts (order, name, `required`, `default`) plus one control (`widget`) and one value shape (`shape`), so the notebook renders forms without per-template code. The core owns names, order, shapes, defaults and requiredness; bindings own widgets, labels and `quickCreate`. A subject shape carries `accepts` and `proven` — the step types whose interfaces the core's unification admits, and the subsumed subset it proves outright — so a producer dropdown offers exactly what meets the consumer's parameter. A template declares only what differs; the widget vocabulary is closed (`text`, `textarea`, `code`, `command`, `number`, `checkbox`, `select`, `tokens`, `list`, `step`, `steps`, `record`, `datetime`) and evaluation fails on a binding that names no core parameter, a presentation override the shape cannot express, an unknown widget, or a widget missing its parameter. `nix eval --json '.#pointy.stepConfig'` yields the document the backend serves.
- `#pointy.steps.<id>` — the step derivation (`outPath`, `drvPath`, `meta.pointy`) carrying its own facts: `def` (the step's record, with its integer `id`), `key` (the step's input address), `dependencies` (the transitive upstream step ids), `srcFiles` where the build links a directory in (template kind `derivation` with `withSrcFiles`, and `srcFiles/<id>` present) — the same path the unpack phase links — and `certificate`.
- `#pointy.steps.<id>.certificate` — the step's certificate, defined lazily for every step: `{ model, certificate, target }`, built from the applications of the step's own producer closure, with `output = steps.<id>` (the raw step) and the certificates of the step's producers as `parents`. The `certificate` derivation has two outputs: `out` is the canonical certificate, `target` the target descriptor of that same run (the path `pointy verify --against` replays against, with `--certificate-drv` naming the derivation). The certificate checks the step's own output against its interface's declared output type and discharges its incoming residuals against its producers' certificates, exporting the facts it observed (including the selected `|` branch per join-typed parameter); a step's certificate succeeding means its output and its whole upstream closure are certified. A step whose `outPath` does not evaluate carries no certificate: forcing the attribute throws, so `builtins.tryEval` catches it. The schema document is read at evaluation; forcing those exports is the flow's other import-from-derivation.
- `#pointy.projects.<pid>` — the project record (`name`, `hidden`, `sortKey`, `preset`, `templates`, `steps`, `validationErrors`, `id`), so the notebook resolves one project per evaluation.
- `#pointy.presets` — the project presets.
- `#pointy.autocomplete` — the template autocomplete hooks.
- `#checks.<system>.pointy-applications` — `pointy check --applications` over every step record: interface from the template contract, arguments with producers in the acquisition envelope, optional `refine` per step. It fails on a `Bottom` edge, never on a residual.

The notebook backend reads each output above, and the flake publishes exactly these.

Records and every host-side argument map are keyed by the core schema's `parameter` name. Templates declare `contract.interface` plus presentation `bindings`; `compile` receives the resolved args. A binding nests one level per shape layer: a list's knobs live under `list`, a record's under `record` (its fields under `record.fields.<name>`), and `quickCreate` sits on the subject leaf itself. A step record may carry a top-level `refine = "<type expression>"`; it is part of the step's declared output type for applications and certificates, and never reaches the step derivation.

The step envelope is the library's, not the template's: `compile { lib, pkgs, pointyLib }` returns `{ build = { args, public }: { name?; version?; env?; mkDerivation; }; }`, and `evalSteps` supplies the `pname` (the step's type unless the template names one), `version = "1"`, the `trotterPackage` marker and the metadata every step carries (`meta.pointy.id`/`type`/`requirements`/`args`). A template declares only what makes it different: `requirements` as an attrset — or a function of the resolved args — merged over `{ ram = "1G"; cpu = 1; ior = "0"; iow = "0"; }`, and `extras = "csv"` or `"fastq"` to have the matching artifact scan attached to its metadata. `nixDepPkgs` resolves `nixDeps` names against the one `pkgs`; `stepLinkCommands` links step dependencies into a build directory under their step ids.

`pointy-stdlib.lib` is the host-facing surface: `mkFlake`, `loadDir`, `csvExtras`, `fastqExtras`, `nixDepPkgs`, `stepLinkCommands`.

See [Setting Up the User Repository](https://github.com/421anon/pointy-demo/blob/main/docs/pages/user-repo-setup.md) for a minimal repository and template examples.
