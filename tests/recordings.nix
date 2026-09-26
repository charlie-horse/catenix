# What each recording in tests/fixtures/recorded/ is: the real
# import-from-derivation call it stands in for, as `pkgs: value`.
#
# The system-agnostic suites read the recordings (`recorded "<name>"`); the
# per-system `contracts.<name>` suites check each one still equals its real
# call, and `legacyPackages.<system>.recordings.<name>` builds it afresh
# (tests/flake-module.nix; re-recording is in docs/DESIGN.md).
{
  catenix,
  fixtures,
  kubernetesSrc,
  certManagerChart,
}:
let
  yaml = file: pkgs: catenix.yaml2json pkgs file;

  # What `importChart` reads back from `helmTemplate`.
  helm = args: pkgs: builtins.fromJSON (builtins.readFile (catenix.helmTemplate pkgs args));

  # tests/fixtures/charts/demo, as release `web` in `apps` with `values`
  # (tests/integration/helm-chart.nix).
  demoWeb =
    values:
    helm {
      chart = fixtures + "/charts/demo";
      release = {
        name = "web";
        namespace = "apps";
      };
      inherit values;
    };
in
{
  crd-widget = yaml "${fixtures}/crd-widget.yaml";
  crd-portal = yaml "${fixtures}/crd-portal.yaml";
  sample-controller-crd = yaml "${kubernetesSrc}/staging/src/k8s.io/sample-controller/artifacts/examples/crd.yaml";

  # tests/unit/chartModule.nix
  demo-rel = helm {
    chart = fixtures + "/charts/demo";
    release = {
      name = "rel";
      namespace = "apps";
    };
  };

  demo-web = demoWeb { };
  demo-web-greeting-hi = demoWeb { greeting = "hi"; };
  demo-web-replicas-3 = demoWeb { replicas = 3; };
  demo-web-replicas-as-string = demoWeb { replicasAsString = true; };
  demo-web-widget-size-0 = demoWeb { widget.size = 0; };
  demo-web-widget-color-pink = demoWeb { widget.color = "pink"; };
  demo-web-widget-color-red = demoWeb { widget.color = "red"; };

  # The `cert-manager-chart` input (v1.21.2) as tests/e2e/helm-cert-manager.nix
  # imports it: CRDs rendered from templates.
  cert-manager = helm {
    chart = certManagerChart;
    release = {
      name = "cert-manager";
      namespace = "cert-manager";
    };
    values.crds.enabled = true;
  };
}
