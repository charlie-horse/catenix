# Unit tests for lib/chartModule.nix: an already-rendered Helm chart (its
# manifest list) as a module — patched, its CRDs typing its custom resources,
# and every object defined through `manifestsToResources`. Pure: the manifests
# are inline Nix, what `helmTemplate` renders for tests/fixtures/charts/demo as
# release `rel` in `apps` (`pkgs` is only an unforced module argument).
{
  lib,
  catenix,
  pkgs,
  helpers,
  catenixModule,
  ...
}:
let
  labels = {
    "app.kubernetes.io/name" = "demo";
    "app.kubernetes.io/instance" = "rel";
  };

  widgetCrd = {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    metadata.name = "widgets.example.com";
    spec = {
      group = "example.com";
      scope = "Namespaced";
      names = {
        kind = "Widget";
        plural = "widgets";
        singular = "widget";
      };
      versions = [
        {
          name = "v1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = {
            type = "object";
            properties.spec = {
              type = "object";
              required = [ "size" ];
              properties = {
                size = {
                  type = "integer";
                  minimum = 1;
                };
                enabled.type = "boolean";
                color = {
                  type = "string";
                  enum = [
                    "red"
                    "green"
                    "blue"
                  ];
                };
              };
            };
          };
          subresources.status = { };
        }
      ];
    };
  };

  # The demo chart's render, in `helm template`'s order.
  demoManifests = [
    widgetCrd
    {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata.name = "rel-sub";
      data.message = "from-sub";
    }
    {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "rel-demo";
        namespace = "apps";
        creationTimestamp = null;
      };
      data = {
        greeting = "hello";
        kubeVersion = "v1.37.0";
      };
    }
    {
      apiVersion = "rbac.authorization.k8s.io/v1";
      kind = "ClusterRole";
      metadata = {
        name = "rel-demo";
        namespace = "apps";
      };
      rules = [
        {
          apiGroups = [ "example.com" ];
          resources = [ "widgets" ];
          verbs = [
            "get"
            "list"
            "watch"
          ];
        }
      ];
    }
    {
      apiVersion = "v1";
      kind = "Service";
      metadata = {
        name = "rel-demo";
        inherit labels;
      };
      spec = {
        selector = labels;
        ports = [
          {
            port = 80;
            targetPort = 8080;
          }
        ];
      };
    }
    {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "rel-demo";
        namespace = "apps";
        inherit labels;
      };
      spec = {
        replicas = 2;
        selector.matchLabels = labels;
        template = {
          metadata = { inherit labels; };
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
                configMap = {
                  name = "rel-demo";
                  defaultMode = 420;
                };
              }
            ];
          };
        };
      };
    }
    {
      apiVersion = "example.com/v1";
      kind = "Widget";
      metadata.name = "rel-demo";
      spec = {
        size = 3;
        enabled = true;
        color = "blue";
      };
    }
    {
      apiVersion = "v1";
      kind = "Pod";
      metadata = {
        name = "rel-demo-test";
        annotations."helm.sh/hook" = "test";
      };
      spec = {
        restartPolicy = "Never";
        containers = [
          {
            name = "wget";
            image = "busybox";
            command = [
              "wget"
              "rel-demo:80"
            ];
          }
        ];
      };
    }
    {
      apiVersion = "batch/v1";
      kind = "Job";
      metadata = {
        name = "rel-demo-migrate";
        annotations = {
          "helm.sh/hook" = "pre-install,pre-upgrade";
          "helm.sh/hook-delete-policy" = "before-hook-creation";
        };
      };
      spec.template.spec = {
        restartPolicy = "Never";
        containers = [
          {
            name = "migrate";
            image = "busybox";
            command = [ "true" ];
          }
        ];
      };
    }
  ];

  chartModuleOf =
    args:
    catenix.chartModule (
      {
        manifests = demoManifests;
        release = {
          name = "rel";
          namespace = "apps";
        };
        chartName = "demo";
      }
      // args
    );

  eval =
    args: modules:
    helpers.eval pkgs (
      [
        catenixModule
        (chartModuleOf args)
      ]
      ++ modules
    );

  manifestsOf = args: modules: (eval args modules).config.build.manifests;

  names = manifests: map (m: "${m.kind}/${m.metadata.name}") manifests;

  find =
    kind: name: manifests:
    lib.findFirst (m: m.kind == kind && m.metadata.name == name) (throw "no ${kind}/${name}") manifests;

  # Namespace, then CRD, then by group, version, kind, name.
  allNames = [
    "CustomResourceDefinition/widgets.example.com"
    "Deployment/rel-demo"
    "Job/rel-demo-migrate"
    "ConfigMap/rel-demo"
    "ConfigMap/rel-sub"
    "Pod/rel-demo-test"
    "Service/rel-demo"
    "Widget/rel-demo"
    "ClusterRole/rel-demo"
  ];

  withoutCrds = {
    manifests = lib.remove widgetCrd demoManifests;
  };
in
{
  testDefinesEveryObject = {
    expr = names (manifestsOf { } [ ]);
    expected = allNames;
  };

  testResourceKeys = {
    expr = lib.mapAttrs (_: lib.attrNames) (
      lib.filterAttrs (_: instances: instances != { }) (eval { } [ ]).config.resources.core.v1
    );
    expected = {
      ConfigMap = [
        "rel-demo"
        "rel-sub"
      ];
      Pod = [ "rel-demo-test" ];
      Service = [ "rel-demo" ];
    };
  };

  # The chart's CRD is imported: its kind is declared (with its scope) and
  # typed, even in strict mode.
  testChartCrdDeclaresKind = {
    expr = (eval { } [ { validation.strict = true; } ]).config.kinds."example.com".v1.Widget.namespaced;
    expected = true;
  };

  testChartCrdTypesCustomResource = {
    expr =
      map
        (
          spec:
          helpers.fails (
            manifestsOf { } [ { resources."example.com".v1.Widget.rel-demo = { inherit spec; }; } ]
          )
        )
        [
          { size = "big"; }
          { color = "pink"; }
          { size = 0; }
          { unknown = 1; }
          { size = 4; }
        ];
    expected = [
      true
      true
      true
      true
      false
    ];
  };

  # The chart's own CRD is emitted too, unchanged but for dropped nulls.
  testChartCrdEmitted = {
    expr = find "CustomResourceDefinition" "widgets.example.com" (manifestsOf { } [ ]);
    expected = widgetCrd;
  };

  # Chart values are `mkDefault`s: a plain definition wins, attrsets merge.
  testOverridesWin = {
    expr =
      let
        deployment = find "Deployment" "rel-demo" (
          manifestsOf { } [
            {
              resources.apps.v1.Deployment.rel-demo = {
                spec.replicas = 5;
                metadata.labels.extra = "x";
              };
            }
          ]
        );
      in
      {
        inherit (deployment.spec) replicas;
        inherit (deployment.metadata) labels;
      };
    expected = {
      replicas = 5;
      labels = labels // {
        extra = "x";
      };
    };
  };

  testNamespaces = {
    expr = map (m: m.metadata.namespace or null) (manifestsOf { } [ ]);
    expected = [
      null
      "apps"
      "apps"
      "apps"
      "apps"
      "apps"
      "apps"
      "apps"
      null
    ];
  };

  testReleaseNamespaceDefaultsToDefault = {
    expr = (find "Service" "rel-demo" (manifestsOf { release.name = "rel"; } [ ])).metadata.namespace;
    expected = "default";
  };

  testPatch = {
    expr = map (m: m.metadata.labels.patched or null) (
      manifestsOf {
        patch = m: lib.recursiveUpdate m { metadata.labels.patched = "yes"; };
      } [ ]
    );
    expected = lib.genList (_: "yes") 9;
  };

  testPatchDropsNull = {
    expr = names (
      manifestsOf {
        patch = m: if m.kind == "Pod" then null else m;
      } [ ]
    );
    expected = lib.remove "Pod/rel-demo-test" allNames;
  };

  # A patched CRD types the custom resources.
  testPatchAppliesToCrds = {
    expr = helpers.fails (
      manifestsOf {
        patch =
          m:
          if m.kind == "CustomResourceDefinition" then
            lib.recursiveUpdate m {
              spec.versions = map (
                v: lib.recursiveUpdate v { schema.openAPIV3Schema.properties.spec.properties.size.maximum = 2; }
              ) m.spec.versions;
            }
          else
            m;
      } [ ]
    );
    expected = true;
  };

  testSkipTests = {
    expr = names (manifestsOf { skipTests = true; } [ ]);
    expected = lib.remove "Pod/rel-demo-test" allNames;
  };

  testNoHooks = {
    expr = names (manifestsOf { noHooks = true; } [ ]);
    expected = lib.subtractLists [ "Pod/rel-demo-test" "Job/rel-demo-migrate" ] allNames;
  };

  # Without the chart's CRD there's nothing to import; the custom resource
  # stays untyped (and is rejected in strict mode).
  testWithoutCrds = {
    expr = {
      declared = (eval withoutCrds [ ]).config.kinds ? "example.com";
      widget = (find "Widget" "rel-demo" (manifestsOf withoutCrds [ ])).spec;
      strictFails = helpers.fails (manifestsOf withoutCrds [ { validation.strict = true; } ]);
    };
    expected = {
      declared = false;
      widget = {
        size = 3;
        enabled = true;
        color = "blue";
      };
      strictFails = true;
    };
  };

  testNoManifests = {
    expr = manifestsOf { manifests = [ ]; } [ ];
    expected = [ ];
  };

  # Type errors name the release: its definitions carry the module's `_file`.
  testDefinitionsNameTheRelease = {
    expr = lib.elem "helm release rel (chart demo)" (eval { } [ ]).options.resources.files;
    expected = true;
  };

  testFileNamesReleaseAndChart = {
    expr =
      (chartModuleOf {
        release.name = "other";
        chartName = "cert-manager";
      })._file;
    expected = "helm release other (chart cert-manager)";
  };
}
