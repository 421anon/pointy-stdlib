# Pointy repository schema for the embedded agent

Schema version: `1`. System: `x86_64-linux`.

A Pointy repository holds steps, projects, templates, and script source files. This document describes the flake outputs that are evaluated from those files and the shape of the files an embedded agent works with. The Markdown itself is published as `pointy.agentSchema`.

## Files in a changeset

The apply flow carries edits from three paths:

- `steps/<numeric-id>.nix`
- `projects/<numeric-id>.nix`
- `srcFiles/<numeric-step-id>/<relative-path>`

Other paths stay outside the changeset. A reviewed step is published read-only, including its `steps/<id>.nix` and `srcFiles/<id>/`.

A step or project file is a Nix file that `nix-instantiate --parse` accepts. The sandbox is for inspection and small checks; a full step workload belongs to a Slurm job. Sandbox commands have a 120-second default timeout, and scratch files belong under `$HOME` rather than the in-memory `/tmp`.

## Schema outputs

All attributes are under `pointy` except `checks`, which is under `checks.<system>`. Step and project ids in attribute names are strings.

| Attribute | Shape | Role |
| --- | --- | --- |
| `pointy.schemaVersion` | integer, `1` | Identifies the output shape and the keyed, certified step model. |
| `pointy.agentSchema` | string | This document. |
| `pointy.stepConfig` | `{ version = 4; templates; }` | The form document. A template entry lists its field names, requiredness, defaults, and shapes. |
| `pointy.steps.<id>` | derivation plus the attributes below | The evaluated step, including its output folder. |
| `pointy.steps.<id>.def` | attribute set | The step file's record, with the integer `id` added. |
| `pointy.steps.<id>.key` | string | Content address of the step's inputs, used to cache build and certificate status. |
| `pointy.steps.<id>.certificate` | `{ model, facts, certificate }` | The derivation that checks the output folder against the step's type expression. |
| `pointy.steps.<id>.dependencies` | list of strings | Transitive upstream step ids, excluding the step itself. |
| `pointy.steps.<id>.srcFiles` | store path, optional | The store copy of `srcFiles/<id>/`, present when the template links a source directory and that directory exists. |
| `pointy.steps.<id>.requirements` | `{ cpu, ram, ior, iow }` | The resolved resource request after the step and template declarations. |
| `pointy.steps.<id>.meta.pointy` | attribute set | The resolved `id` (string), `type`, `requirements`, `args`, with `notices` and `extras` when present. |
| `pointy.projects.<pid>` | attribute set | The evaluated project record, including `children` and `validationErrors`. |
| `pointy.root` | attribute set | The folder tree, with Turtle links for artifact permalinks. |
| `pointy.staleDependencies` | list | Dependency references whose recorded project path no longer holds the referenced step. |
| `pointy.presets` | attribute set | Preset records, keyed by the names a project's `preset` field can use. |
| `pointy.autocomplete` | attribute set | Suggestion hooks for form fields, keyed by template. |
| `checks.x86_64-linux.pointy-applications` | derivation | The full application check over every step record. |

## Step files

A step file is one attribute set:

```nix
{
  type = "<template>";
  name = "<name>";
  args = { <parameter> = <value>; };
  note = "<text>";
  about = [ "https://example.org/record" ];
  requirements = { cpu = 1; ram = "1G"; ior = "0"; iow = "0"; };
  refine = "<type expression>";
  reviewedRevision = "<commit>";
  reviewedBy = "<name>";
  reviewComments = "<text>";
}
```

- `type` names a template from `pointy.stepConfig` and `args` supplies its parameters; both are required. A missing template is reported as `pointy.step <id>: the repository has no template '<type>'`, and argument mistakes as `pointy.<type>: unknown arg(s): ...` or `pointy.<type>: missing required arg(s): ...`.
- `name` is the display name.
- `note` is free text.
- `about` is a list of absolute `http(s)` URLs recorded beside the step.
- `requirements` replaces the template's resource request rather than merging with it.
- `refine` adds a type expression to the step's output type. It affects which downstream steps accept the output and what the certificate checks, not the build derivation.
- `reviewedRevision`, `reviewedBy`, and `reviewComments` are the review metadata the backend writes for a reviewed step.

The filename supplies the step id, which is sparse and appears as an integer `id` in `pointy.steps.<id>.def`; a new step takes the highest existing step id plus one. A step file is imported on its own, so a sibling file or another repository path is not reachable from it.

`args` follows the template's parameter names. A producer parameter holds `{ step = N; }` or `{ path = [ P Q ]; step = N; }`; an ordered family of producers holds a list of those references. `path` lists project ids from a child of the root project down to the project holding step N. The root project `0` never appears. The path records where the reference appeared for permalink purposes: the build follows `.step`, and a stale path is reported and treated like `{ step = N; }`. A missing producer is reported as `pointy.step <id>: the producer '<id>' is not defined`.

## Project files

A project file holds:

```nix
{
  name = "<name>";
  preset = "<preset>";
  children = [
    { step = { id = 42; hidden = false; sortKey = null; }; }
    { project = { id = 7; hidden = false; sortKey = null; }; }
  ];
}
```

- `name` is the display name.
- Exactly one of `preset` and `templates` is present. `preset` names a key of `pointy.presets`; `templates` is a list of template names. Having both or neither is an evaluation error.
- `children` holds entries tagged with `step` or `project`. `hidden` controls display, and `sortKey` is an integer or `null`.
- The filename supplies the project id, which appears as an integer `id` in `pointy.projects.<pid>`; a new project takes the highest existing project id plus one.

A project's children come from the entries its file lists; duplicate entries for the same step or project are collapsed. A new project file stays invisible until a parent lists it; an entry in `projects/0.nix` puts it at the top level. A step file with no project entry is unfiled.

`projects/0.nix` is the root project, Home. It is never a child of another project and is not deleted.

A step or project can be listed in several parents. The project graph stays acyclic; a project never appears under one of its own descendants.

Children display with integer `sortKey` values first in ascending order, then entries without a `sortKey`, with ties broken by id.

An entry whose step or project file does not exist is dropped and reported in `pointy.projects.<pid>.validationErrors`. An unknown preset or template is reported there as well.

## Source directories

`srcFiles/<id>/` is the step's source directory. It is copied with the step and linked into the build working directory when the template's kind is `derivation` with `withSrcFiles`; other templates ignore it. A reviewed step's source directory is read-only.

## Evaluation and apply

A changeset is accepted when the projects and steps it changes evaluate and it introduces no stale dependency references. Evaluation failures already present on the target branch do not block it; a refusal reports the failures and the affected file.

A step file or its source directory moves the step's key and the keys of the steps that consume it. A dependency reference's `path` affects links and stale-reference reporting, not the build derivation. Keys and certificates are content-addressed outputs, not handles for editing a step.

The embedded agent's turn ends before a build. Once a changeset is applied, the user runs the step and the backend reports its build and certificate status.

## Reading the schema

The Markdown is obtained with:

```sh
nix eval --raw .#pointy.agentSchema
```

The same evaluation exposes:

```sh
nix eval --json .#pointy.stepConfig
nix eval --json .#pointy.projects
nix eval --json .#pointy.steps.42.def
nix eval --json .#pointy.staleDependencies
```

`--raw` returns strings and store paths; `--json` returns records and lists. `pointy.stepConfig.templates.<type>.fields` lists each parameter's name, requiredness, default, and shape. A shape's `kind` is `text`, `int`, `bool`, `choice`, `list`, `record`, or `artifact`; an `artifact` shape lists the producer types it accepts.
