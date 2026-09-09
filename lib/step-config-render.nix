# Builder expression for the host-generated stepConfig derivation: read
# the core schema + host adapter build inputs, reject adapter tables that
# break the schema's structural rules (unknown binding names, builder
# arguments colliding with core parameters, allowedTypes naming no
# template, interface identity), and emit the merged document.
# renderStepConfig rejects presentation overlays that break the schema
# with its own precise message, so this gate only covers what the
# renderer cannot see.  Pure, nixpkgs-free; run via nix-instantiate
# --json; a non-empty problem list fails the build.
{ schemaPath, adapterPath, stepConfigPath }:
let
  stepConfigPure = import stepConfigPath { };
  schema = builtins.fromJSON (builtins.readFile schemaPath);
  adapter = builtins.fromJSON (builtins.readFile adapterPath);
  problems = stepConfigPure.validateAdapterStructure { inherit schema adapter; };
in
if problems != [ ] then
  throw (
    "pointy host adapter rejected over the core schema:\n  "
    + builtins.concatStringsSep "\n  " problems
  )
else
  stepConfigPure.renderStepConfig { inherit schema adapter; }
