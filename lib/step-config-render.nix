# Builder expression for the host-generated stepConfig derivation: read
# the core schema + host adapter build inputs and emit the merged
# document.  Pure, nixpkgs-free; run via nix-instantiate --json.
{ schemaPath, adapterPath, stepConfigPath }:
let
  stepConfigPure = import stepConfigPath { };
in
stepConfigPure.renderStepConfig {
  schema = builtins.fromJSON (builtins.readFile schemaPath);
  adapter = builtins.fromJSON (builtins.readFile adapterPath);
}
