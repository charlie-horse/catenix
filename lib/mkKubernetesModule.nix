# `mkKubernetesModule { kubernetesSrc, apis ? "default" }`: the resource
# module for the built-in API of a Kubernetes source tree, from its OpenAPI v3
# documents (`api/openapi-spec/v3/*.json`, those with `components`) and
# aggregated discovery (`api/discovery/aggregated_v2.json`, if present). `apis`
# is passed to `kubernetes.loadKubernetes`: "default" (the group/versions a
# default cluster serves), "all", or a list of group/versions. No derivations:
# the source is already in the store, so its files are read directly.
{ lib, catenix }:
{
  kubernetesSrc,
  apis ? "default",
}:
let
  specDir = "${kubernetesSrc}/api/openapi-spec/v3";
  discoveryFile = "${kubernetesSrc}/api/discovery/aggregated_v2.json";

  openapi = lib.filter (document: document ? components) (
    map (name: lib.importJSON "${specDir}/${name}") (
      lib.filter (lib.hasSuffix ".json") (lib.attrNames (builtins.readDir specDir))
    )
  );

  discovery = if builtins.pathExists discoveryFile then lib.importJSON discoveryFile else null;
in
assert lib.assertMsg (builtins.pathExists specDir)
  "catenix.mkKubernetesModule: ${toString kubernetesSrc} has no api/openapi-spec/v3 directory";
catenix.resourceModule.mkResourceModule (
  catenix.kubernetes.loadKubernetes { inherit openapi discovery apis; }
)
