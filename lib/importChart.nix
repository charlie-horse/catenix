# `importChart { pkgs, chart, release, values ? { }, kubeVersion ? null,
# apiVersions ? [ ], includeCrds ? true, extraArgs ? [ ], patch ? (m: m),
# noHooks ? false, skipTests ? false }`: a Helm chart as a module.
#
# `helmTemplate` renders the chart; its JSON is read back with
# `builtins.fromJSON` (import-from-derivation). `patch` maps each manifest
# (returning `null` drops it). The chart's `apiextensions.k8s.io/v1`
# CustomResourceDefinitions are imported (`crd.loadCrds` +
# `resourceModule.mkResourceModule`), so its custom resources are typed, and
# every manifest, CRDs included, is defined through `manifestsToResources`
# (release namespace filled in, `mkDefault` priority, hooks per
# `noHooks`/`skipTests`). Type errors surface when `build.manifests` (or
# `build.yaml`) is evaluated.
{ lib, catenix }:
{
  pkgs,
  chart,
  release,
  values ? { },
  kubeVersion ? null,
  apiVersions ? [ ],
  includeCrds ? true,
  extraArgs ? [ ],
  patch ? (manifest: manifest),
  noHooks ? false,
  skipTests ? false,
}:
let
  rendered = catenix.helmTemplate pkgs {
    inherit
      chart
      release
      values
      kubeVersion
      apiVersions
      includeCrds
      extraArgs
      ;
  };

  manifests = builtins.filter (manifest: manifest != null) (
    map patch (builtins.fromJSON (builtins.readFile rendered))
  );

  crds = builtins.filter (
    manifest:
    manifest.apiVersion or null == "apiextensions.k8s.io/v1"
    && manifest.kind or null == "CustomResourceDefinition"
  ) manifests;
in
{
  # Where type errors say the chart's definitions come from.
  _file = "helm release ${release.name} (chart ${baseNameOf (toString chart)})";

  imports =
    lib.optional (crds != [ ]) (catenix.resourceModule.mkResourceModule (catenix.crd.loadCrds crds))
    ++ [
      (catenix.manifestsToResources {
        inherit manifests noHooks skipTests;
        namespace = release.namespace or "default";
      })
    ];
}
