# Unit tests for lib/manifestsToResources.nix: plain manifests (as `helm
# template` renders them) -> a module defining `resources` at `mkDefault`
# priority. Checked behaviourally against the real core types
# (`nixosModules.default`) plus two CRD kinds, through `build.manifests`.
{
  lib,
  catenix,
  pkgs,
  helpers,
  catenixModule,
  ...
}:
let
  inherit (catenix) manifestsToResources;

  crd = kind: scope: {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    metadata.name = "${lib.toLower kind}s.example.com";
    spec = {
      group = "example.com";
      inherit scope;
      names = {
        inherit kind;
        plural = "${lib.toLower kind}s";
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
              properties.size.type = "integer";
            };
          };
        }
      ];
    };
  };

  # Namespaced Widget, cluster-scoped Knob.
  crdModule = catenix.resourceModule.mkResourceModule (
    catenix.crd.loadCrds [
      (crd "Widget" "Namespaced")
      (crd "Knob" "Cluster")
    ]
  );

  eval =
    modules:
    helpers.eval pkgs (
      [
        catenixModule
        crdModule
      ]
      ++ modules
    );

  # The manifests of `manifests` imported with `args`, plus `modules`.
  manifestsWith =
    args: manifests: modules:
    (eval ([ (manifestsToResources (args // { inherit manifests; })) ] ++ modules))
    .config.build.manifests;

  render = manifests: manifestsWith { namespace = "apps"; } manifests [ ];

  failsWith =
    args: manifests: modules:
    helpers.fails (manifestsWith args manifests modules);

  # `{ kind = name; }` of rendered manifests, to check which are kept.
  names = manifests: map (m: "${m.kind}/${m.metadata.name}") manifests;

  deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      name = "web";
      namespace = "apps";
      labels.app = "web";
    };
    spec = {
      replicas = 2;
      selector.matchLabels.app = "web";
      template = {
        metadata.labels.app = "web";
        spec = {
          containers = [
            {
              name = "web";
              image = "nginx:1.27";
            }
          ];
          volumes = [
            {
              name = "scratch";
              emptyDir = { };
            }
          ];
        };
      };
    };
  };

  service = {
    apiVersion = "v1";
    kind = "Service";
    metadata.name = "web";
    spec.ports = [ { port = 80; } ];
  };

  clusterRole = {
    apiVersion = "rbac.authorization.k8s.io/v1";
    kind = "ClusterRole";
    metadata = {
      name = "reader";
      namespace = "apps";
    };
    rules = [
      {
        apiGroups = [ "" ];
        resources = [ "pods" ];
        verbs = [ "get" ];
      }
    ];
  };

  configMap = name: {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = { inherit name; };
    data.key = "value";
  };

  hook = event: name: {
    apiVersion = "batch/v1";
    kind = "Job";
    metadata = {
      inherit name;
      annotations."helm.sh/hook" = event;
    };
    spec.template.spec = {
      restartPolicy = "Never";
      containers = [
        {
          name = "run";
          image = "busybox";
        }
      ];
    };
  };

  hooks = [
    (configMap "plain")
    (hook "pre-install,pre-upgrade" "migrate")
    (hook "test" "smoke")
    (hook "test-success" "legacy-smoke")
  ];
in
{
  # Round trip: identity fields stripped, then injected back by render.

  testTypedRoundTrip = {
    expr = render [ deployment ];
    expected = [ deployment ];
  };

  testCoreGroup = {
    expr = render [ (configMap "settings") ];
    expected = [
      (
        (configMap "settings")
        // {
          metadata.name = "settings";
          metadata.namespace = "apps";
        }
      )
    ];
  };

  testKeyedByGroupVersionKindName = {
    expr = lib.attrNames (
      (eval [
        (manifestsToResources {
          manifests = [
            deployment
            service
          ];
        })
      ]).config.resources.apps.v1.Deployment
    );
    expected = [ "web" ];
  };

  testEmptyAttrsetKept = {
    expr = (lib.elemAt (render [ deployment ]) 0).spec.template.spec.volumes;
    expected = [
      {
        name = "scratch";
        emptyDir = { };
      }
    ];
  };

  testListsFlattened = {
    expr = names (render [
      {
        apiVersion = "v1";
        kind = "List";
        items = [
          (configMap "a")
          (configMap "b")
        ];
      }
    ]);
    expected = [
      "ConfigMap/a"
      "ConfigMap/b"
    ];
  };

  # Namespaces: filled in for namespaced kinds only, as `kubectl apply -n`.

  testInjectsNamespace = {
    expr = (lib.head (render [ service ])).metadata;
    expected = {
      name = "web";
      namespace = "apps";
    };
  };

  testKeepsOwnNamespace = {
    expr =
      (lib.head (render [ (lib.recursiveUpdate service { metadata.namespace = "other"; }) ])).metadata;
    expected = {
      name = "web";
      namespace = "other";
    };
  };

  testNoNamespaceWithoutReleaseNamespace = {
    expr = (lib.head (manifestsWith { } [ service ] [ ])).metadata;
    expected.name = "web";
  };

  testClusterScopedNamespaceDropped = {
    expr = (lib.head (render [ clusterRole ])).metadata;
    expected.name = "reader";
  };

  testCustomNamespacedKind = {
    expr = map (m: m.metadata) (render [
      {
        apiVersion = "example.com/v1";
        kind = "Widget";
        metadata.name = "w";
        spec.size = 1;
      }
      {
        apiVersion = "example.com/v1";
        kind = "Knob";
        metadata = {
          name = "k";
          namespace = "apps";
        };
        spec.size = 1;
      }
    ]);
    expected = [
      { name = "k"; }
      {
        name = "w";
        namespace = "apps";
      }
    ];
  };

  testUntypedKindGetsNamespace = {
    expr = render [
      {
        apiVersion = "monitoring.example.io/v1";
        kind = "Probe";
        metadata.name = "p";
        spec.interval = "30s";
      }
    ];
    expected = [
      {
        apiVersion = "monitoring.example.io/v1";
        kind = "Probe";
        metadata = {
          name = "p";
          namespace = "apps";
        };
        spec.interval = "30s";
      }
    ];
  };

  # Overrides: plain definitions win field by field.

  testOverrideWinsFieldByField = {
    expr =
      (lib.head (
        manifestsWith { }
          [ deployment ]
          [
            {
              resources.apps.v1.Deployment.web = {
                spec.replicas = 5;
                metadata.labels.tier = "front";
              };
            }
          ]
      )).spec.replicas;
    expected = 5;
  };

  testOverrideKeepsOtherFields = {
    expr =
      let
        m = lib.head (
          manifestsWith { } [ deployment ] [ { resources.apps.v1.Deployment.web.spec.replicas = 5; } ]
        );
      in
      {
        inherit (m.metadata) labels;
        image = (lib.head m.spec.template.spec.containers).image;
      };
    expected = {
      labels.app = "web";
      image = "nginx:1.27";
    };
  };

  testAttrsMerge = {
    expr =
      (lib.head (
        manifestsWith { }
          [ deployment ]
          [ { resources.apps.v1.Deployment.web.metadata.labels.tier = "front"; } ]
      )).metadata.labels;
    expected = {
      app = "web";
      tier = "front";
    };
  };

  testListReplaced = {
    expr =
      (lib.head (
        manifestsWith { }
          [ deployment ]
          [
            {
              resources.apps.v1.Deployment.web.spec.template.spec.containers = [
                {
                  name = "api";
                  image = "api:2";
                }
              ];
            }
          ]
      )).spec.template.spec.containers;
    expected = [
      {
        name = "api";
        image = "api:2";
      }
    ];
  };

  testNullRemovesField = {
    expr =
      (lib.head (
        manifestsWith { } [ deployment ] [ { resources.apps.v1.Deployment.web.spec.replicas = null; } ]
      )).spec
        ? replicas;
    expected = false;
  };

  testOverrideUntypedKind = {
    expr =
      (lib.head (
        manifestsWith { }
          [
            {
              apiVersion = "monitoring.example.io/v1";
              kind = "Probe";
              metadata.name = "p";
              spec = {
                interval = "30s";
                targets = [ "a" ];
              };
            }
          ]
          [ { resources."monitoring.example.io".v1.Probe.p.spec.interval = "1m"; } ]
      )).spec;
    expected = {
      interval = "1m";
      targets = [ "a" ];
    };
  };

  # Type checking still applies.

  testWrongTypeFails = {
    expr = failsWith { } [ (lib.recursiveUpdate deployment { spec.replicas = "2"; }) ] [ ];
    expected = true;
  };

  testUnknownFieldFails = {
    expr = failsWith { } [ (lib.recursiveUpdate deployment { spec.replicaz = 2; }) ] [ ];
    expected = true;
  };

  testUnknownKindFailsWhenStrict = {
    expr =
      failsWith { }
        [
          {
            apiVersion = "monitoring.example.io/v1";
            kind = "Probe";
            metadata.name = "p";
          }
        ]
        [ { validation.strict = true; } ];
    expected = true;
  };

  # Server-set fields and nulls are stripped.

  testStripsServerSetFields = {
    expr = render [
      (lib.recursiveUpdate (configMap "c") {
        metadata = {
          creationTimestamp = null;
          uid = "1234";
          resourceVersion = "42";
          generation = 3;
          managedFields = [ { manager = "helm"; } ];
          selfLink = "/api/v1/namespaces/apps/configmaps/c";
          deletionTimestamp = "2026-01-01T00:00:00Z";
          deletionGracePeriodSeconds = 30;
        };
        status = { };
      })
    ];
    expected = [
      (
        (configMap "c")
        // {
          metadata.name = "c";
          metadata.namespace = "apps";
        }
      )
    ];
  };

  testStripsStatusOfTypedKind = {
    expr = render [
      (
        deployment
        // {
          status = {
            replicas = 0;
          };
        }
      )
    ];
    expected = [ deployment ];
  };

  testStripsNulls = {
    expr = render [
      (lib.recursiveUpdate deployment {
        spec.strategy = null;
        metadata.annotations = null;
      })
    ];
    expected = [ deployment ];
  };

  # Hooks: kept unless asked otherwise.

  testHooksKeptByDefault = {
    expr = names (manifestsWith { } hooks [ ]);
    # Sorted by group: batch before core.
    expected = [
      "Job/legacy-smoke"
      "Job/migrate"
      "Job/smoke"
      "ConfigMap/plain"
    ];
  };

  testHookAnnotationKept = {
    expr = (lib.elemAt (manifestsWith { } hooks [ ]) 1).metadata.annotations;
    expected."helm.sh/hook" = "pre-install,pre-upgrade";
  };

  testSkipTests = {
    expr = names (manifestsWith { skipTests = true; } hooks [ ]);
    expected = [
      "Job/migrate"
      "ConfigMap/plain"
    ];
  };

  testNoHooks = {
    expr = names (manifestsWith { noHooks = true; } hooks [ ]);
    expected = [ "ConfigMap/plain" ];
  };

  testTestAmongSeveralEventsIsTest = {
    expr = names (manifestsWith { skipTests = true; } [ (hook "pre-install, test" "both") ] [ ]);
    expected = [ ];
  };

  # Errors.

  testDuplicateFails = {
    expr =
      failsWith { }
        [
          (configMap "same")
          (lib.recursiveUpdate (configMap "same") { metadata.namespace = "other"; })
        ]
        [ ];
    expected = true;
  };

  testMissingNameFails = {
    expr =
      failsWith { }
        [
          {
            apiVersion = "v1";
            kind = "ConfigMap";
            metadata.generateName = "c-";
          }
        ]
        [ ];
    expected = true;
  };

  testMissingKindFails = {
    expr =
      failsWith { }
        [
          {
            apiVersion = "v1";
            metadata.name = "c";
          }
        ]
        [ ];
    expected = true;
  };

  testNoManifests = {
    expr = render [ ];
    expected = [ ];
  };
}
