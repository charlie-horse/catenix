# A Helm chart as type-checked resources: cert-manager, pulled with
# `fetchChart` (a fixed-output `helm pull`), rendered by `helm template`, its
# objects defined in `resources` at `mkDefault` priority and checked against
# the Kubernetes types and the chart's own CRDs. Plain definitions override
# the chart field by field, and a custom resource of a kind the chart defines
# is typed by its CRD. Render it with:
#
#   nix run .#render -- examples/helm.nix
{ pkgs, catenix, ... }:
{
  imports = [
    (catenix.importChart {
      inherit pkgs;
      chart = catenix.fetchChart pkgs {
        repo = "https://charts.jetstack.io";
        name = "cert-manager";
        version = "v1.21.2";
        hash = "sha256-AsbUc4Q9aVfTmENGPPmjOwC6V6v3MpTN1cKIl8csi10=";
      };
      release = {
        name = "cert-manager";
        namespace = "cert-manager";
      };
      values = {
        crds.enabled = true;
        prometheus.enabled = false;
      };
      # The chart's post-install API check Job (and its RBAC) only makes
      # sense under `helm install`.
      noHooks = true;
    })
  ];

  validation.strict = true;

  resources = {
    core.v1.Namespace.cert-manager = { };

    # Overrides the chart's `replicaCount`-derived value; the rest of the
    # Deployment is the chart's.
    apps.v1.Deployment.cert-manager.spec.replicas = 2;

    "cert-manager.io".v1.ClusterIssuer.self-signed.spec.selfSigned = { };
  };
}
