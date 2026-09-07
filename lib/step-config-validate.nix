# Builder expression for the host conformance check: read the core
# schema + host adapter build inputs and emit the flat problem list.
# The gate fails when the list is non-empty.  Pure, nixpkgs-free.
{ schemaPath, adapterPath, stepConfigPath }:
let
  stepConfigPure = import stepConfigPath { };
in
stepConfigPure.validateHostAdapter {
  schema = builtins.fromJSON (builtins.readFile schemaPath);
  adapter = builtins.fromJSON (builtins.readFile adapterPath);
}
