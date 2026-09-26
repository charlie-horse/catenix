# Unit tests for lib/importChart.nix: `chartModule` over `helmTemplate`'s
# render, read back (import-from-derivation), so this suite is per-system
# (tests/per-system.nix) and is one smoke case for the adapter's wiring: the
# render arguments reach `helm template`, the module arguments reach
# `chartModule`. The module itself is tests/unit/chartModule.nix, over the
# recording of the same chart (kept equal to helm's render by
# `contracts.demo-rel`); rendering is tests/unit/helmTemplate.nix. The fixture
# chart is tests/fixtures/charts/demo.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  helpers,
  catenixModule,
  ...
}:
let
  evaluated = helpers.eval pkgs [
    catenixModule
    (catenix.importChart {
      inherit pkgs;
      chart = fixtures + "/charts/demo";
      # No namespace: "default".
      release.name = "rel";
      values.replicas = 4;
      includeCrds = false;
      skipTests = true;
      patch = m: lib.recursiveUpdate m { metadata.labels.patched = "yes"; };
    })
  ];
  inherit (evaluated) config;

  find =
    kind: name:
    lib.findFirst (m: m.kind == kind && m.metadata.name == name) (throw "no ${kind}/${name}");
in
{
  testSmoke = {
    expr = {
      names = map (m: "${m.kind}/${m.metadata.name}") config.build.manifests;
      replicas = (find "Deployment" "rel-demo" config.build.manifests).spec.replicas;
      serviceNamespace = (find "Service" "rel-demo" config.build.manifests).metadata.namespace;
      patched = lib.all (m: m.metadata.labels.patched == "yes") config.build.manifests;
      crdDeclared = config.kinds ? "example.com";
      namesRelease = lib.elem "helm release rel (chart demo)" evaluated.options.resources.files;
    };
    expected = {
      # No CRD (`includeCrds`), no test Pod (`skipTests`).
      names = [
        "Deployment/rel-demo"
        "Job/rel-demo-migrate"
        "ConfigMap/rel-demo"
        "ConfigMap/rel-sub"
        "Service/rel-demo"
        "Widget/rel-demo"
        "ClusterRole/rel-demo"
      ];
      replicas = 4;
      serviceNamespace = "default";
      patched = true;
      crdDeclared = false;
      namesRelease = true;
    };
  };
}
