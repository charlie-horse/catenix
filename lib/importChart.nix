# `importChart { pkgs, chart, release, values ? { }, kubeVersion ? null,
# apiVersions ? [ ], includeCrds ? true, extraArgs ? [ ], patch ? (m: m),
# noHooks ? false, skipTests ? false }`: a Helm chart as a module.
#
# A thin adapter: `helmTemplate` renders the chart and its JSON is read back
# with `builtins.fromJSON` (import-from-derivation, the only one here); the
# rest (`patch`, CRD import, `manifestsToResources`, the `_file` naming the
# release) is `chartModule`, with the chart's base name as `chartName`.
{ catenix, ... }:
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
catenix.chartModule {
  manifests = builtins.fromJSON (
    builtins.readFile (
      catenix.helmTemplate pkgs {
        inherit
          chart
          release
          values
          kubeVersion
          apiVersions
          includeCrds
          extraArgs
          ;
      }
    )
  );
  chartName = baseNameOf (toString chart);
  inherit
    release
    patch
    noHooks
    skipTests
    ;
}
