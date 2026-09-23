# A small web app: podinfo as a `Deployment` configured from a `ConfigMap`,
# behind a `Service`. Every field is type-checked against the pinned
# Kubernetes API: `replicas = "2"` or a misspelled field is an evaluation
# error. Render it with:
#
#   nix run .#render -- examples/basic.nix
let
  namespace = "demo";
  labels.app = "podinfo";
in
{
  resources.core.v1.ConfigMap.podinfo = {
    metadata = { inherit namespace labels; };
    data = {
      PODINFO_UI_MESSAGE = "Hello from catenix";
      PODINFO_UI_COLOR = "#34577c";
    };
  };

  resources.apps.v1.Deployment.podinfo = {
    metadata = { inherit namespace labels; };
    spec = {
      replicas = 2;
      selector.matchLabels = labels;
      template = {
        metadata = { inherit labels; };
        spec.containers = [
          {
            name = "podinfo";
            image = "ghcr.io/stefanprodan/podinfo:6.7.1";
            envFrom = [ { configMapRef.name = "podinfo"; } ];
            ports = [
              {
                name = "http";
                containerPort = 9898;
              }
            ];
            # Quantities: strings with a unit suffix, or plain numbers.
            resources = {
              requests = {
                cpu = "250m";
                memory = "64Mi";
              };
              limits = {
                cpu = 1;
                memory = "128Mi";
              };
            };
            # Probe and target ports are int-or-string: a port name or number.
            readinessProbe = {
              httpGet = {
                path = "/readyz";
                port = "http";
              };
              periodSeconds = 5;
            };
            livenessProbe = {
              httpGet = {
                path = "/healthz";
                port = 9898;
              };
              initialDelaySeconds = 10;
            };
          }
        ];
      };
    };
  };

  resources.core.v1.Service.podinfo = {
    metadata = { inherit namespace labels; };
    spec = {
      selector = labels;
      ports = [
        {
          name = "http";
          port = 80;
          targetPort = "http";
        }
      ];
    };
  };
}
