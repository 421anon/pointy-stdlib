# Pointy embedded-agent flake schema

Schema version: `1`. System: `x86_64-linux`.

This is the embedded agent's reference for the user-repository flake. Read it from the repository root:

```sh
nix eval --raw .#pointy.agentSchema
```

## Editable surface

The backend applies only:

- `steps/<numeric-id>.nix`
- `projects/<numeric-id>.nix`
- `srcFiles/<numeric-step-id>/<relative-path>`

Edits elsewhere are discarded. Reviewed steps are read-only: their `steps/<id>.nix` and `srcFiles/<id>/` cannot be changed.

Before ending a turn that edits a step or project file, run `nix-instantiate --parse <file>` on every edited file and fix what it reports.

Use the sandbox for inspection and small checks only. Do not run a full step workload; finish the step file and ask the user to run it. Bash commands stop after 120 seconds unless they set a longer `timeout`. Keep scratch files and DuckDB `temp_directory` under `$HOME`, not `/tmp`.

## Whole schema

All attributes are under `pointy` except `checks`, which is under `checks.<system>`. Step and project ids in attribute names are strings.

| Attribute | Shape | Embedded-agent use |
| --- | --- | --- |
| `pointy.schemaVersion` | integer, `1` | Marks keyed steps and certificates. Read-only. |
| `pointy.agentSchema` | string | This document. |
| `pointy.stepConfig` | `{ version = 4; templates; }` | Valid template names, field names, defaults, and shapes. Use it to write `type` and `args`. |
| `pointy.steps.<id>` | derivation plus the attributes below | Current evaluated step. Not an edit surface. |
| `pointy.steps.<id>.def` | attribute set | The step file's content with the integer `id` added. |
| `pointy.steps.<id>.key` | string | Content address used by the backend to cache status. Do not edit or reuse. |
| `pointy.steps.<id>.certificate` | `{ model, facts, certificate }` | The build target that checks the output type. Not an edit surface. |
| `pointy.steps.<id>.dependencies` | list of strings | Transitive upstream step ids, excluding the step itself. |
| `pointy.steps.<id>.srcFiles` | store path, optional | Store copy of `srcFiles/<id>/`; present when the template uses it and the directory exists. |
| `pointy.steps.<id>.requirements` | `{ cpu, ram, ior, iow }` | Resolved resources after the step or template declaration. |
| `pointy.steps.<id>.meta.pointy` | attribute set | Resolved `id` (string), `type`, `requirements`, `args`, plus `notices` and `extras` when present. |
| `pointy.projects.<pid>` | attribute set | Evaluated project record, including `validationErrors` and `children`. |
| `pointy.root` | attribute set | Folder tree with Turtle links. Not needed to edit files. |
| `pointy.staleDependencies` | list | Dependency references that are stale; fix any you introduce. |
| `pointy.presets` | attribute set | Valid values for a project's `preset`. |
| `pointy.autocomplete` | attribute set | Field suggestion hooks. Not used to validate edits. |
| `checks.x86_64-linux.pointy-applications` | derivation | Full application check. Not run by the embedded agent. |

## `steps/<id>.nix`

The file imports as one plain attribute set:

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

Only these top-level fields are interpreted:

- `type` and `args` are required. A definition without either fails evaluation.
- `name` is the display name.
- `note` is free text.
- `about` is a list of absolute `http(s)` URLs recorded beside the step. Other values are not published.
- `requirements` replaces the template's requirements entirely; it is not merged with the defaults. Include all four fields when present.
- `refine` is a type expression added to the step's declared output type. It affects downstream compatibility and certification, not the build derivation.
- `reviewedRevision`, `reviewedBy`, and `reviewComments` are review metadata. The backend manages them; never add or change them.

Do not write `id`; the evaluator adds it as an integer to `def`. The filename supplies the id. Ids are sparse; a new step uses the highest existing id plus one.

`args` is keyed by the template parameter names from `pointy.stepConfig`. A producer parameter takes `{ step = N; }` or `{ path = [ P Q ]; step = N; }`. `path` lists project ids from a child of the root project down to the project holding step N; root `0` is never written. The path is link metadata: builds ignore it, but the backend records it and refuses an apply that introduces a stale path. A list of producers takes a list of those references. A missing producer raises `pointy.step <id>: the producer '<id>' is not defined`.

A step file is imported alone. It cannot import a sibling file or read another repository path. The template name must exist; otherwise evaluation raises `pointy.step <id>: the repository has no template '<type>'`. Arguments are checked against the template: `pointy.<type>: unknown arg(s): ...` or `pointy.<type>: missing required arg(s): ...`.

## `projects/<id>.nix`

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
- Exactly one of `preset` and `templates` is required. `preset` names a key of `pointy.presets`; `templates` is a list of template names. Both or neither fails evaluation.
- `children` entries link a step or subproject. `hidden` controls display; `sortKey` is an integer or `null`.
- Do not write `id`; the evaluator adds it as an integer to `pointy.projects.<pid>`. The filename supplies the id; a new project uses the highest existing project id plus one.

A child appears in this project only while an entry lists it. A new project file is invisible until a parent lists it; add its entry to `projects/0.nix` to place it at the top level. A step file with no project entry is unfiled.

`projects/0.nix` is the root project, Home. It is never a child of another project and cannot be deleted.

A step or project may be listed in several parents. The project graph must stay a DAG; never link a project under one of its own descendants.

Children display in this order: integer `sortKey` values ascending, then entries without a `sortKey`, with ties broken by id.

An entry whose step or project file does not exist is dropped and reported in `pointy.projects.<pid>.validationErrors`. An unknown preset or template is also reported there. Fix the entry or the missing file; do not leave validation errors behind.

## `srcFiles/<id>/`

`srcFiles/<id>/` is copied with the step and linked into the build working directory when the template's kind is `derivation` with `withSrcFiles`. For other templates the directory is ignored. The step's source files belong here.

Reviewed steps cannot change, so their `srcFiles/<id>/` is read-only.

## Evaluation and apply

A changeset is refused when it introduces evaluation failures in the projects or steps it changes, or when it would introduce stale dependency references. Failures that already exist on the target branch do not block it. Fix the reported file and resubmit.

Changing a step or its `srcFiles/` moves that step's key and the keys of the steps that consume it. Builds ignore a dependency reference's `path`; it only affects links and stale-reference checks. Do not treat a key or certificate as an edit handle.

The agent does not build or certify steps. After a changeset is applied, the user runs the step; the backend then reports its build and certificate status.

## Inspecting

```sh
nix eval --raw .#pointy.agentSchema
nix eval --json .#pointy.stepConfig
nix eval --json .#pointy.projects
nix eval --json .#pointy.steps.42.def
nix eval --json .#pointy.staleDependencies
```

Use `--raw` for strings and store paths, `--json` for records and lists. Read `pointy.stepConfig.templates.<type>.fields` for parameter names, requiredness, defaults, and shape; `shape.kind` is `text`, `int`, `bool`, `choice`, `list`, `record`, or `artifact`. An `artifact` shape lists the producer types it accepts.
