# Unit tests for lib/importCrdModule.nix: `crdModule` over `yaml2json` of a
# YAML file. Parsing YAML is import-from-derivation, so this suite is
# per-system (tests/per-system.nix) and is one smoke case for the adapter's
# wiring. What the module declares and types is tests/unit/crdModule.nix, over
# the recording of the same file (kept equal to `yaml2json` by
# `contracts.crd-widget`); YAML parsing itself is tests/unit/yaml2json.nix.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  helpers,
  ...
}:
let
  inherit (catenix) importCrdModule;

  resourcesOf =
    crdFile: config:
    (helpers.eval pkgs [
      (importCrdModule { inherit pkgs crdFile; })
      config
    ]).config.resources;

  # Config values as plain data: unset (null) optional fields dropped.
  plain =
    value:
    if lib.isAttrs value then
      lib.mapAttrs (_: plain) (lib.filterAttrs (_: v: v != null) value)
    else if lib.isList value then
      map plain value
    else
      value;

  rejects = crdFile: config: helpers.fails (plain (resourcesOf crdFile config));
in
{
  # The file, as a string or a path, is parsed and its CRDs type instances;
  # a file yq can't parse fails.
  testSmoke = {
    expr = {
      typed = plain (
        resourcesOf "${fixtures}/crd-widget.yaml" {
          resources."example.com".v1.Widget.small = {
            metadata.namespace = "default";
            spec.size = 1;
          };
        }
      );
      pathFile = plain (resourcesOf (fixtures + "/crd-widget.yaml") { });
      wrongType = rejects (fixtures + "/crd-widget.yaml") {
        resources."example.com".v1.Widget.bad.spec.size = "big";
      };
      unparsable = rejects (pkgs.writeText "broken.yaml" "a: [unclosed\n") { };
    };
    expected = {
      typed."example.com".v1.Widget.small = {
        metadata.namespace = "default";
        spec.size = 1;
      };
      pathFile."example.com".v1.Widget = { };
      wrongType = true;
      unparsable = true;
    };
  };
}
