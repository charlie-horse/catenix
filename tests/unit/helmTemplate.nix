# Unit tests for lib/helmTemplate.nix: `helm template` in a derivation whose
# output is one JSON array of manifests. Reading the output back is
# import-from-derivation, so tests/flake-module.nix runs this suite at
# evaluation time. The fixture chart is tests/fixtures/charts/demo.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  ...
}:
let
  helmTemplate = catenix.helmTemplate pkgs;

  chart = fixtures + "/charts/demo";
  release = {
    name = "rel";
    namespace = "apps";
  };

  render = args: helmTemplate ({ inherit chart release; } // args);
  manifestsOf = args: builtins.fromJSON (builtins.readFile (render args));

  demo = manifestsOf { };

  # "<Kind>/<name>" of each manifest, sorted.
  names = manifests: lib.sort lib.lessThan (map (m: "${m.kind}/${m.metadata.name}") manifests);

  find =
    kind: name: manifests:
    lib.findFirst (m: m.kind == kind && m.metadata.name == name) (throw "no ${kind}/${name}") manifests;

  failureLog = drv: builtins.readFile "${pkgs.testers.testBuildFailure drv}/testBuildFailure.log";
in
{
  testIsJsonFileDerivation = {
    expr = {
      inherit (render { }) name;
      isDerivation = lib.isDerivation (render { });
    };
    expected = {
      name = "helm-template-rel.json";
      isDerivation = true;
    };
  };

  # CRDs from crds/, templates (with `include`d helpers), the vendored
  # subchart, and hooks (a Job and a test Pod); the comment-only document is
  # dropped.
  testRendersEveryDocument = {
    expr = names demo;
    expected = [
      "ClusterRole/rel-demo"
      "ConfigMap/rel-demo"
      "ConfigMap/rel-sub"
      "CustomResourceDefinition/widgets.example.com"
      "Deployment/rel-demo"
      "Job/rel-demo-migrate"
      "Pod/rel-demo-test"
      "Service/rel-demo"
      "Widget/rel-demo"
    ];
  };

  testNoEmptyDocuments = {
    expr = lib.all (m: lib.isAttrs m && m != { }) demo;
    expected = true;
  };

  testDeployment = {
    expr = find "Deployment" "rel-demo" demo;
    expected = {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "rel-demo";
        namespace = "apps";
        labels = {
          "app.kubernetes.io/name" = "demo";
          "app.kubernetes.io/instance" = "rel";
        };
      };
      spec = {
        replicas = 2;
        selector.matchLabels = {
          "app.kubernetes.io/name" = "demo";
          "app.kubernetes.io/instance" = "rel";
        };
        template = {
          metadata.labels = {
            "app.kubernetes.io/name" = "demo";
            "app.kubernetes.io/instance" = "rel";
          };
          spec = {
            containers = [
              {
                name = "web";
                image = "nginx:1.27";
                ports = [ { containerPort = 8080; } ];
                volumeMounts = [
                  {
                    name = "config";
                    mountPath = "/etc/demo";
                  }
                ];
              }
            ];
            volumes = [
              {
                name = "config";
                # `0644` read as YAML 1.1 octal, as Kubernetes does.
                configMap = {
                  name = "rel-demo";
                  defaultMode = 420;
                };
              }
            ];
          };
        };
      };
    };
  };

  # `yes` read as a YAML 1.1 boolean, as Kubernetes does.
  testYaml11Boolean = {
    expr = (find "Widget" "rel-demo" demo).spec;
    expected = {
      size = 3;
      enabled = true;
      color = "blue";
    };
  };

  # Quoted strings stay strings; `null`s are kept (dropping them is
  # manifestsToResources' job).
  testQuotedScalarsStayStrings = {
    expr =
      let
        cm = find "ConfigMap" "rel-demo" (manifestsOf {
          values.greeting = "on";
        });
      in
      {
        inherit (cm.data) greeting;
        inherit (cm.metadata) creationTimestamp;
      };
    expected = {
      greeting = "on";
      creationTimestamp = null;
    };
  };

  testValues = {
    expr =
      let
        manifests = manifestsOf {
          values = {
            replicas = 5;
            image.tag = "1.28";
            widget.color = "red";
          };
        };
      in
      {
        inherit ((find "Deployment" "rel-demo" manifests).spec) replicas;
        image = (lib.head (find "Deployment" "rel-demo" manifests).spec.template.spec.containers).image;
        inherit ((find "Widget" "rel-demo" manifests).spec) color;
      };
    expected = {
      replicas = 5;
      image = "nginx:1.28";
      color = "red";
    };
  };

  testSubchartValues = {
    expr =
      (find "ConfigMap" "rel-sub" (manifestsOf {
        values.sub.message = "hi";
      })).data;
    expected.message = "hi";
  };

  testRelease = {
    expr = names (manifestsOf {
      release = {
        name = "other";
        namespace = "ns";
      };
    });
    expected = [
      "ClusterRole/other-demo"
      "ConfigMap/other-demo"
      "ConfigMap/other-sub"
      "CustomResourceDefinition/widgets.example.com"
      "Deployment/other-demo"
      "Job/other-demo-migrate"
      "Pod/other-demo-test"
      "Service/other-demo"
      "Widget/other-demo"
    ];
  };

  testReleaseNamespace = {
    expr =
      (find "Deployment" "other-demo" (manifestsOf {
        release.name = "other";
      })).metadata.namespace;
    expected = "default";
  };

  testKubeVersion = {
    expr =
      (find "ConfigMap" "rel-demo" (manifestsOf {
        kubeVersion = "1.30.2";
      })).data.kubeVersion;
    expected = "v1.30.2";
  };

  testApiVersions = {
    expr = map (args: (find "ConfigMap" "rel-demo" (manifestsOf args)).data.widgetsV2 or null) [
      { }
      { apiVersions = [ "example.com/v2" ]; }
    ];
    expected = [
      null
      "true"
    ];
  };

  testWithoutCrds = {
    expr = lib.any (m: m.kind == "CustomResourceDefinition") (manifestsOf {
      includeCrds = false;
    });
    expected = false;
  };

  testExtraArgs = {
    expr = names (manifestsOf {
      extraArgs = [
        "--skip-tests"
        "--no-hooks"
      ];
    });
    expected = [
      "ClusterRole/rel-demo"
      "ConfigMap/rel-demo"
      "ConfigMap/rel-sub"
      "CustomResourceDefinition/widgets.example.com"
      "Deployment/rel-demo"
      "Service/rel-demo"
      "Widget/rel-demo"
    ];
  };

  testStorePathChart = {
    expr = names (manifestsOf {
      chart = builtins.path {
        path = chart;
        name = "demo";
      };
    });
    expected = names demo;
  };

  testMissingDependencyFailsBuild = {
    expr =
      let
        log = failureLog (helmTemplate {
          chart = fixtures + "/charts/missing-dep";
          inherit release;
        });
      in
      map (s: lib.hasInfix s log) [
        "missing in charts/ directory: postgresql"
        "vendored under the chart's charts/ directory"
      ];
    expected = [
      true
      true
    ];
  };

  testTemplateErrorFailsBuild = {
    expr =
      let
        log = failureLog (render {
          values.image = "not-a-map";
        });
      in
      map (s: lib.hasInfix s log) [
        "Error: demo/templates/deployment.yaml"
        "helmTemplate: helm template failed"
      ];
    expected = [
      true
      true
    ];
  };
}
