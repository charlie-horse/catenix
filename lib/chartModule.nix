# `chartModule { manifests, release, chartName, patch ? (m: m),
# noHooks ? false, skipTests ? false }`: an already-rendered Helm chart as a
# module. Pure; `importChart` is this over `helmTemplate`'s output.
#
# `patch` maps each manifest (returning `null` drops it). The chart's
# `apiextensions.k8s.io/v1` CustomResourceDefinitions are imported
# (`crdModule`), so its custom resources are typed, and every manifest, CRDs
# included, is defined through `manifestsToResources` (release namespace
# filled in, `mkDefault` priority, hooks per `noHooks`/`skipTests`). The
# module's `_file` names the release and `chartName`, so type errors do too;
# they surface when `build.manifests` (or `build.yaml`) is evaluated.
{ lib, catenix }:
{
  manifests,
  release,
  chartName,
  patch ? (manifest: manifest),
  noHooks ? false,
  skipTests ? false,
}:
let
  patched = builtins.filter (manifest: manifest != null) (map patch manifests);

  crds = builtins.filter (
    manifest:
    manifest.apiVersion or null == "apiextensions.k8s.io/v1"
    && manifest.kind or null == "CustomResourceDefinition"
  ) patched;
in
{
  # Where type errors say the chart's definitions come from.
  _file = "helm release ${release.name} (chart ${chartName})";

  imports = lib.optional (crds != [ ]) (catenix.crdModule crds) ++ [
    (catenix.manifestsToResources {
      manifests = patched;
      inherit noHooks skipTests;
      namespace = release.namespace or "default";
    })
  ];
}
