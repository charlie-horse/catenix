# The real pinned Kubernetes spec, through `nixosModules.default`.
{
  pkgs,
  helpers,
  catenixModule,
  ...
}:
let
  eval = modules: helpers.eval pkgs ([ catenixModule ] ++ modules);

  valid = eval [
    {
      resources.core.v1.ConfigMap.settings = {
        metadata.namespace = "default";
        data."app.conf" = "debug = true";
      };
      resources.apps.v1.Deployment.web = {
        metadata.namespace = "default";
        spec = {
          replicas = 2;
          selector.matchLabels.app = "web";
          template = {
            metadata.labels.app = "web";
            spec.containers = [
              {
                name = "web";
                image = "nginx:1.27";
                ports = [ { containerPort = 80; } ];
              }
            ];
          };
        };
      };
    }
  ];
in
{
  testYaml = {
    expr = builtins.readFile valid.config.build.yaml;
    expected = ''
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web
        namespace: default
      spec:
        replicas: 2
        selector:
          matchLabels:
            app: web
        template:
          metadata:
            labels:
              app: web
          spec:
            containers:
              - image: nginx:1.27
                name: web
                ports:
                  - containerPort: 80
      ---
      apiVersion: v1
      data:
        app.conf: debug = true
      kind: ConfigMap
      metadata:
        name: settings
        namespace: default
    '';
  };

  testWrongFieldTypeFails = {
    expr =
      helpers.fails
        (eval [ { resources.apps.v1.Deployment.bad.spec.replicas = "two"; } ]).config.build.manifests;
    expected = true;
  };

  testMissingRequiredFieldFails = {
    expr =
      helpers.fails
        (eval [
          {
            resources.apps.v1.Deployment.bad.spec.template.spec.containers = [ { image = "nginx"; } ];
          }
        ]).config.build.manifests;
    expected = true;
  };

  testIntOrString = {
    expr =
      helpers.fails
        (eval [
          {
            resources.core.v1.Service.svc.spec.ports = [
              {
                port = 80;
                targetPort = "http";
              }
              {
                port = 81;
                targetPort = 8081;
              }
            ];
          }
        ]).config.build.manifests;
    expected = false;
  };
}
