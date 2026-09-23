# Read-only outputs rendered from `resources`: thin wiring over lib/render.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  render = import ../lib/render.nix { inherit lib; };
in
{
  options.build = {
    manifests = mkOption {
      type = types.listOf (types.attrsOf types.anything);
      readOnly = true;
      description = ''
        The plain Kubernetes manifests of `resources`, with `apiVersion`,
        `kind` and `metadata.name` filled in and unset (`null`) fields
        dropped. Namespaces come first, then CustomResourceDefinitions, then
        everything else sorted by group, version, kind and name, so the list
        applies in one pass.
      '';
    };

    yaml = mkOption {
      type = types.package;
      readOnly = true;
      description = ''
        A multi-document YAML file of `build.manifests`, ready for
        `kubectl apply -f`.
      '';
    };
  };

  config.build = {
    manifests = render.manifestsFromResources config.resources;
    yaml = render.toYaml pkgs config.build.manifests;
  };
}
