# Pointy user-repository flake schema

Schema version: `1`. System: `x86_64-linux`.

This document is the agent-facing contract for the flake a Pointy user repository exposes. Read it from the repository root:

```sh
nix eval --raw .#pointy.agentSchema
```

The notebook backend reads the other `pointy.*` attributes. It does not read `pointy.agentSchema`; that attribute exists so agents can read this schema without guessing from examples.

## Repository contract

A user repository is a Git-backed flake. `flake.nix` delegates to pointy-stdlib:

```nix
{
  inputs = {
    pointy-stdlib.url = "github:421anon/pointy-stdlib";
    nixpkgs.follows = "pointy-stdlib/nixpkgs";
  };

  outputs = inputs@{ pointy-stdlib, ... }:
    pointy-stdlib.lib.mkFlake { inherit inputs; };
}
```

`pointy.nix` supplies the package set and the language entry program:

```nix
{ inputs, ... }:
{
  pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
  source = ./main.pointy;
}
```

Required paths: `flake.nix`, `pointy.nix`, `main.pointy`, `templates/`, `steps/`, and `flake.lock`. Optional paths: `packages/`, `presets/`, `projects/`, and `srcFiles/`.

- `templates/` and `steps/` are read from the repository. Every regular `<id>.nix` in `steps/` is a step; the filename without `.nix` is the step id.
- `projects/` is optional; `projects/0.nix` is the root folder.
- `presets/` is optional; every file is a preset.
- `main.pointy` must be one file. It is not copied with its directory.
- The global source is one store copy of `flake.nix`, `pointy.nix`, `templates/`, `packages/`, and `main.pointy`. Steps, projects, and presets are read from the repository itself.
- Each `steps/<id>.nix` is imported alone as `step.nix`. It cannot import a sibling file or read outside its own source directory. `srcFiles/<id>/` is copied separately as `srcFiles` for templates whose kind is `derivation` with `withSrcFiles`.
- A change to `flake.nix`, `pointy.nix`, `templates/`, `packages/`, `main.pointy`, or `flake.lock` moves the global source or lock hash and therefore every step key. A change to `steps/<id>.nix` or `srcFiles/<id>/` moves that step's key and the keys of its consumers.

`mkFlake` takes `inputs`, optional `src` (defaults to the flake's own source), and optional `modules` for flake-parts configuration. Modules receive `pointyRepo` with `{ src, globalSrc, cfg, rev }`, where `cfg` is the result of `pointy.nix`. Modules may add ordinary flake outputs; they must not replace the `pointy` attributes described here.

## Outputs

All schema attributes are directly under `pointy`, with no system suffix.

| Attribute | Type | Meaning |
| --- | --- | --- |
| `pointy.schemaVersion` | integer | `1`. A repository without it predates keyed steps and certificates. |
| `pointy.agentSchema` | string | This Markdown document. |
| `pointy.stepConfig` | attribute set | Version 4 form document for the notebook. |
| `pointy.steps.<id>` | derivation plus attributes | Step `<id>`, keyed by the string form of the id. |
| `pointy.steps.<id>.def` | attribute set | The step file's record, with the integer `id` added. |
| `pointy.steps.<id>.key` | string | Content address of the step's inputs. |
| `pointy.steps.<id>.certificate` | attribute set | `{ model, facts, certificate }` for this step. |
| `pointy.steps.<id>.dependencies` | list of strings | Transitive upstream step ids, excluding the step itself. |
| `pointy.steps.<id>.srcFiles` | store path | Present only when the template links a source directory and `srcFiles/<id>/` exists. |
| `pointy.steps.<id>.requirements` | attribute set | Resolved `{ cpu, ram, ior, iow }`. |
| `pointy.projects.<pid>` | attribute set | Evaluated folder record; `0` is the root folder. |
| `pointy.root` | attribute set | Folder tree starting at the root folder. |
| `pointy.staleDependencies` | list of attribute sets | Dependency references whose recorded folder path no longer holds the step. |
| `pointy.presets` | attribute set | Preset records keyed by preset name. |
| `pointy.autocomplete` | attribute set | Autocomplete hooks keyed by template name. |
| `checks.x86_64-linux.pointy-applications` | derivation | `pointy check --applications` over all step records. |

### `pointy.stepConfig`

The version 4 form document:

```text
{
  version = 4;
  templates.<template> = {
    displayName; description; sortKey; icon; kind; fields;
    withSrcFiles?; accepts?;
  };
}
```

Each field is `{ name, label, help, readOnly, required, default, widget, shape }`, plus `path` where a field addresses a nested value. `kind` is `derivation`, `upload`, or `download`. A template's `withSrcFiles` is present for derivation kinds; `accepts` is present for upload kinds.

Shape kinds: `text`, `int`, `bool`, `choice` (`options`), `list` (`element`), `record` (`fields`), `artifact` (`accepts`, `proven`, `create`). Widget kinds: `text`, `textarea`, `code`, `command`, `number`, `checkbox`, `select`, `tokens`, `list`, `step`, `steps`, `record`, `datetime`.

The document is generated from the language interface and template bindings. Evaluation fails on an unknown parameter binding, an override the shape cannot express, an unknown widget, or a widget missing a required parameter. Do not edit `stepConfig` by hand; change the language declaration or the template binding.

### `pointy.steps.<id>`

`pointy.steps.<id>` is the raw step derivation and carries these additional attributes:

- `def` is the imported step record with an integer `id`. It normally holds `type`, `name`, `args`, and may hold `requirements`, `refine`, `note`, and review fields.
- `key` is `sha256` of the JSON record `{ version, nix, lock, global, step, srcFiles, producers }`: the key format version, the Nix version, the repository's `flake.lock` hash, the global source path, the step file path, the source directory path or `null`, and the producer keys with missing producers recorded as `null`. Forcing a key for a step whose file fails to import raises that import error.
- `dependencies` lists transitive upstream ids as strings. Builds use only the producer references in the step's own arguments.
- `srcFiles` is the store copy of `srcFiles/<id>/` that the unpack phase links. It is absent when the template does not use a source directory or the directory is missing.
- `requirements` is the resolved resource request. A step-level `requirements` overrides the template's declaration; otherwise the template's attribute set or function result is merged over `{ ram = "1G"; cpu = 1; ior = "0"; iow = "0"; }`.
- `certificate` is `{ model, facts, certificate }`. `certificate` is a derivation with `out` (the canonical certificate) and `exports` (its export document). Certificates are keyed by application content, not step id, so equal steps with equal producers share a certificate. A step whose `outPath` does not evaluate has no certificate; forcing it throws.
- `meta.pointy` carries `id` (string), `type`, `requirements`, and the resolved `args`, plus any template notices or extras.

`args` in `meta.pointy` are resolved: defaults are applied, producer references become the producer derivations, and the step id is added as a string. A missing template, missing producer, or a definition without `type` or `args` raises a located error.

A dependency reference is `{ step = N; }` or `{ path = [ P Q ]; step = N; }`. `path` lists folder ids from the root folder's child down to the folder that holds step N; the root id `0` is never written. Builds ignore `path`, so keys, outputs, and certificates do not move when it changes. The notebook keeps it current for commit-addressed permalinks.

### `pointy.projects.<pid>`

A project record holds `name`, `preset`, `templates`, `children`, `validationErrors`, and the integer `id`. Exactly one of `preset` and `templates` is non-null; defining both or neither raises an error.

`children` keeps the file's order of tagged entries. A step child is `{ step = { id, hidden, sortKey, ... }; }` and gains that step's `def`. A project child is `{ project = { id, hidden, sortKey }; }` and remains a reference, so one folder may sit under several parents. An entry whose step or project does not exist is dropped and reported in `validationErrors`.

### `pointy.root`

The folder tree starts at root project `0`. Each node has `steps.<id>` for the steps linked directly in that folder, and `<pid>` for each child folder, recursively. A step value is exactly `pointy.steps.<id>` plus:

- `turtle`: an RDF Turtle document for the artifact permalink `/artifact/<folder ids>/<id>/<commit>`. It describes a `prov:Collection` and a `pointy:Step`, with the step name, template, `prov:wasDerivedFrom` upstream artifacts, and `schema:about` links. Store paths and activity times are omitted.
- `fileTurtle`: a function `{ path, query } -> string` for one file in that output, addressed as `/artifact/<folder ids>/<id>/<commit>?path=<query>`. `path` is the path inside the output; `query` is its percent-encoded form. A query containing any other character throws. The result describes a `prov:Entity` with the file name and lists it with `prov:hadMember`.

All IRIs carry the flake's own commit (`self.rev`). Forcing `turtle` or `fileTurtle` in a flake without a committed revision throws `pointy: linked data needs a committed revision`.

A step linked in several folders appears in each folder node. The path recorded in a dependency selects the folder used for its permalink, not the derivation.

### `pointy.staleDependencies`

A list sorted by dependent step id. Each entry is `{ step = <integer dependent id>; dependency = <reference as written>; }`. A reference is stale when its recorded `path` does not resolve to a folder that directly holds the step. A stale reference evaluates exactly like `{ step = N; }`; the step's `meta.pointy.notices` gains an `info` notice naming the folder and the fallback.

### `pointy.presets` and `pointy.autocomplete`

`pointy.presets` is keyed by preset filename. Each record carries its declared fields plus `description` and `sortKey`, with `null` when absent. A preset that names an unknown template raises an error.

`pointy.autocomplete` is keyed by template name. A template without an `autocomplete` declaration gets `{}`. A declaration is called with `{ pkgs, lib }` and returns the named suggestion functions.

## Inspecting the schema

```sh
nix eval --raw .#pointy.agentSchema
nix eval --json .#pointy.schemaVersion
nix eval --json .#pointy.stepConfig
nix eval --json .#pointy.projects
nix eval --raw .#pointy.steps.42.key
nix eval --json .#pointy.steps.42.def
nix eval --json .#pointy.steps.42.meta.pointy
nix eval --json .#pointy.steps.42.requirements
nix build .#pointy.steps.42
nix build .#pointy.steps.42.certificate
nix build .#checks.x86_64-linux.pointy-applications
```

Use `--raw` for strings and store paths, `--json` for records and lists.

## Agent rules

- Read this document before changing `flake.nix`, `pointy.nix`, `templates/`, `steps/`, or anything that consumes a `pointy.*` attribute.
- Treat the attribute names and shapes above as the public boundary. Do not invent attributes or infer a shape from one repository's output.
- Step ids in output attribute names are strings; `def.id` and dependency entries use integers.
- A key or certificate is content-addressed. Do not patch a store path or reuse one across steps; change inputs and let evaluation compute a new key.
- `pointy.agentSchema` is documentation. If it conflicts with an evaluated output, the evaluated output wins; report the conflict instead of silently adapting to it.
