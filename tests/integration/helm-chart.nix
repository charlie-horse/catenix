# Fixture-driven: a Helm chart (tests/fixtures/charts/demo) imported with
# `importChart` next to `nixosModules.default`, in strict mode, end to end:
# rendered by helm, type-checked by the core types and the chart's own CRD,
# overridden by the user, rendered to YAML.
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
  eval =
    values: modules:
    lib.evalModules {
      modules = [
        catenixModule
        { validation.strict = true; }
        (
          { pkgs, catenix, ... }:
          {
            imports = [
              (catenix.importChart {
                inherit pkgs values;
                chart = fixtures + "/charts/demo";
                release = {
                  name = "web";
                  namespace = "apps";
                };
              })
            ];
          }
        )
      ]
      ++ modules;
      # As a user would: `pkgs` and `catenix` in `specialArgs`, for `imports`.
      specialArgs = { inherit pkgs catenix; };
    };

  manifestsOf = values: modules: (eval values modules).config.build.manifests;
  failsWith = values: modules: helpers.fails (manifestsOf values modules);

  find =
    kind: name: manifests:
    lib.findFirst (m: m.kind == kind && m.metadata.name == name) (throw "no ${kind}/${name}") manifests;

  deploymentOf = manifests: find "Deployment" "web-demo" manifests;
in
{
  testManifests = {
    expr = map (m: {
      inherit (m) apiVersion kind;
      inherit (m.metadata) name;
      namespace = m.metadata.namespace or null;
    }) (manifestsOf { } [ ]);
    expected = [
      {
        apiVersion = "apiextensions.k8s.io/v1";
        kind = "CustomResourceDefinition";
        name = "widgets.example.com";
        namespace = null;
      }
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        name = "web-demo";
        namespace = "apps";
      }
      {
        apiVersion = "batch/v1";
        kind = "Job";
        name = "web-demo-migrate";
        namespace = "apps";
      }
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "web-demo";
        namespace = "apps";
      }
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        name = "web-sub";
        namespace = "apps";
      }
      {
        apiVersion = "v1";
        kind = "Pod";
        name = "web-demo-test";
        namespace = "apps";
      }
      {
        apiVersion = "v1";
        kind = "Service";
        name = "web-demo";
        namespace = "apps";
      }
      {
        apiVersion = "example.com/v1";
        kind = "Widget";
        name = "web-demo";
        namespace = "apps";
      }
      {
        apiVersion = "rbac.authorization.k8s.io/v1";
        kind = "ClusterRole";
        name = "web-demo";
        namespace = null;
      }
    ];
  };

  # Server-set `creationTimestamp: null` stripped, namespace kept.
  testConfigMap = {
    expr = find "ConfigMap" "web-demo" (manifestsOf { greeting = "hi"; } [ ]);
    expected = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "web-demo";
        namespace = "apps";
      };
      data = {
        greeting = "hi";
        kubeVersion = "v1.37.0";
      };
    };
  };

  testYaml = {
    expr =
      let
        yaml = builtins.readFile (eval { } [ ]).config.build.yaml;
      in
      map (s: lib.hasInfix s yaml) [
        "kind: CustomResourceDefinition"
        "defaultMode: 420"
        "helm.sh/hook: pre-install,pre-upgrade"
        ''
          kind: Widget
          metadata:
            name: web-demo
            namespace: apps
          spec:
            color: blue
            enabled: true
            size: 3
        ''
      ];
    expected = [
      true
      true
      true
      true
    ];
  };

  # A plain definition wins over the chart's, field by field.
  testUserOverrideWins = {
    expr =
      let
        deployment = deploymentOf (
          manifestsOf { } [
            {
              resources.apps.v1.Deployment.web-demo = {
                spec.replicas = 7;
                metadata.labels.team = "platform";
              };
            }
          ]
        );
      in
      {
        inherit (deployment.spec) replicas;
        inherit (deployment.metadata) labels;
        image = (lib.head deployment.spec.template.spec.containers).image;
      };
    expected = {
      replicas = 7;
      labels = {
        "app.kubernetes.io/name" = "demo";
        "app.kubernetes.io/instance" = "web";
        team = "platform";
      };
      image = "nginx:1.27";
    };
  };

  testValuesChange = {
    expr = (deploymentOf (manifestsOf { replicas = 3; } [ ])).spec.replicas;
    expected = 3;
  };

  # `replicas: "2"`: rendered fine by helm, rejected by the Deployment type.
  testWronglyTypedRenderFails = {
    expr = failsWith { replicasAsString = true; } [ ];
    expected = true;
  };

  # The chart's Widget is typed by the chart's CRD: a value the CRD rejects
  # (below `minimum`, outside the `enum`) fails, from values or overrides.
  testCustomResourceTypedByChartCrd = {
    expr = [
      (failsWith { widget.size = 0; } [ ])
      (failsWith { widget.color = "pink"; } [ ])
      (failsWith { } [ { resources."example.com".v1.Widget.web-demo.spec.size = "big"; } ])
      (failsWith { widget.color = "red"; } [ ])
    ];
    expected = [
      true
      true
      true
      false
    ];
  };

  testStrictRejectsUnknownKinds = {
    expr = failsWith { } [ { resources."example.com".v1.Gadget.g = { }; } ];
    expected = true;
  };
}
