# The `resources.<group|core>.<version>.<Kind>.<name>` option and strict mode.
# Kinds are declared by `resourceModule` modules, whose `resources` submodules
# merge into this one; anything else is freeform unless `validation.strict`.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  # group -> version -> kind -> name -> body
  untypedResources = types.attrsOf (
    types.attrsOf (types.attrsOf (types.attrsOf (types.attrsOf types.anything)))
  );
in
{
  options = {
    validation.strict = lib.mkEnableOption "strict Kubernetes resource typing";

    resources = mkOption {
      type = types.submodule {
        freeformType = if config.validation.strict then null else untypedResources;
      };
      default = { };
      description = ''
        Kubernetes resources, as `resources.<group>.<version>.<Kind>.<name>`
        with the core group spelled `core`. Each value is the resource's body
        without `apiVersion`, `kind` or `metadata.name`, which are derived from
        its key. Declared kinds are type-checked against their schema; others
        are accepted untyped unless `validation.strict` is set.
      '';
    };
  };
}
