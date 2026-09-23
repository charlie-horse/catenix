# Unit tests for lib/kubernetes.nix: resource schema records from parsed
# OpenAPI v3 documents and aggregated discovery.
{
  lib,
  catenix,
  fixtures,
  helpers,
  ...
}:
let
  inherit (catenix.kubernetes) loadKubernetes;

  openapi = lib.importJSON "${fixtures}/openapi-minimal.json";
  discovery = lib.importJSON "${fixtures}/discovery-minimal.json";

  # Records without their schema attrsets, in a stable order.
  summary =
    records:
    lib.sortOn (r: "${r.group}/${r.version}/${r.kind}") (
      map (
        r:
        removeAttrs r [
          "schema"
          "definitions"
        ]
      ) records
    );

  kinds = records: lib.sort lib.lessThan (map (r: r.kind) records);

  # Builders for small inline documents.
  gvk = group: version: kind: { inherit group version kind; };
  kindSchema = gvks: {
    type = "object";
    x-kubernetes-group-version-kind = gvks;
  };
  op = group: version: kind: { x-kubernetes-group-version-kind = gvk group version kind; };
  doc = paths: schemas: {
    inherit paths;
    components = { inherit schemas; };
  };

  # One discovery group `example.io`, version `v1`, with the given resources.
  exampleDiscovery = resources: {
    items = [
      {
        metadata.name = "example.io";
        versions = [
          {
            version = "v1";
            inherit resources;
          }
        ];
      }
    ];
  };
  resource = plural: kind: scope: {
    resource = plural;
    responseKind = {
      group = "";
      version = "";
      inherit kind;
    };
    inherit scope;
  };

  fixtureGadget = {
    group = "";
    version = "v1";
    kind = "Gadget";
    namespaced = true;
  };
  fixtureGizmo = {
    group = "example.io";
    version = "v1";
    kind = "Gizmo";
    namespaced = false;
  };

  # Every path shape the scope rules distinguish, without discovery.
  pathsDoc =
    doc
      {
        "/api/v1/knobs".post = op "" "v1" "Knob";
        "/api/v1/knobs/{name}".get = op "" "v1" "Knob";
        "/api/v1/dials".get = op "" "v1" "Dial";
        "/api/v1/watch/dials".get = op "" "v1" "Dial";
        "/api/v1/namespaces/{namespace}/dials".post = op "" "v1" "Dial";
        "/api/v1/namespaces/{namespace}/dials/{name}/status".get = op "" "v1" "Dial";
        "/apis/example.io/v1/levers" = {
          parameters = [ { name = "pretty"; } ];
          post = op "example.io" "v1" "Lever";
        };
        "/apis/example.io/v1/switches".get = op "example.io" "v1" "Switch";
        "/apis/example.io/v1/namespaces/{namespace}/switches".post = op "example.io" "v1" "Switch";
        "/apis/example.io/v1/namespaces/{namespace}/switches/{name}/scale" = {
          get = op "autoscaling" "v1" "Scale";
        };
      }
      {
        "io.example.Knob" = kindSchema [ (gvk "" "v1" "Knob") ];
        "io.example.Dial" = kindSchema [ (gvk "" "v1" "Dial") ];
        "io.example.Lever" = kindSchema [ (gvk "example.io" "v1" "Lever") ];
        "io.example.Switch" = kindSchema [ (gvk "example.io" "v1" "Switch") ];
        "io.example.Scale" = kindSchema [ (gvk "autoscaling" "v1" "Scale") ];
        "io.example.Orphan" = kindSchema [ (gvk "example.io" "v1" "Orphan") ];
        "io.example.Plain" = {
          type = "object";
        };
      };

  # One kind at every kind of version: GA (`v1`, `v2`), beta, alpha, plus a
  # core GA and a core alpha kind.
  versionsDoc =
    doc
      {
        "/api/v1/knobs".get = op "" "v1" "Knob";
        "/api/v1alpha1/dials".get = op "" "v1alpha1" "Dial";
        "/apis/example.io/v1/widgets".get = op "example.io" "v1" "Widget";
        "/apis/example.io/v2/widgets".get = op "example.io" "v2" "Widget";
        "/apis/example.io/v2beta1/widgets".get = op "example.io" "v2beta1" "Widget";
        "/apis/example.io/v3alpha2/widgets".get = op "example.io" "v3alpha2" "Widget";
      }
      {
        "io.example.Knob" = kindSchema [ (gvk "" "v1" "Knob") ];
        "io.example.Dial" = kindSchema [ (gvk "" "v1alpha1" "Dial") ];
        "io.example.Widget" = kindSchema [
          (gvk "example.io" "v1" "Widget")
          (gvk "example.io" "v2" "Widget")
          (gvk "example.io" "v2beta1" "Widget")
          (gvk "example.io" "v3alpha2" "Widget")
        ];
      };

  groupVersions =
    records:
    lib.sort lib.lessThan (
      lib.unique (map (r: if r.group == "" then r.version else "${r.group}/${r.version}") records)
    );

  loadVersions = args: groupVersions (loadKubernetes ({ openapi = [ versionsDoc ]; } // args));

  # A kind whose schema has no `paths` of its own, scoped by discovery only.
  gizmoOnlyDoc = doc { } { inherit (openapi.components.schemas) "io.example.Gizmo"; };
in
{
  testFixtureRecords = {
    expr = summary (loadKubernetes {
      openapi = [ openapi ];
      inherit discovery;
    });
    expected = [
      fixtureGadget
      fixtureGizmo
    ];
  };

  testFixtureSchemasAndDefinitions = {
    expr = map (r: { inherit (r) kind schema definitions; }) (
      lib.sortOn (r: r.kind) (loadKubernetes {
        openapi = [ openapi ];
        inherit discovery;
      })
    );
    expected = [
      {
        kind = "Gadget";
        schema = openapi.components.schemas."io.example.Gadget";
        definitions = openapi.components.schemas;
      }
      {
        kind = "Gizmo";
        schema = openapi.components.schemas."io.example.Gizmo";
        definitions = openapi.components.schemas;
      }
    ];
  };

  testFixtureWithoutDiscovery = {
    expr = summary (loadKubernetes {
      openapi = [ openapi ];
    });
    expected = [
      fixtureGadget
      fixtureGizmo
    ];
  };

  testListKindsSkipped = {
    expr = kinds (loadKubernetes {
      openapi = [
        (doc
          {
            "/apis/example.io/v1/widgets" = {
              get = op "example.io" "v1" "WidgetList";
              post = op "example.io" "v1" "Widget";
            };
          }
          {
            "io.example.Widget" = kindSchema [ (gvk "example.io" "v1" "Widget") ];
            "io.example.WidgetList" = kindSchema [ (gvk "example.io" "v1" "WidgetList") ];
          }
        )
      ];
    });
    expected = [ "Widget" ];
  };

  # Namespaced kinds also appear at the all-namespaces `/api/<v>/<plural>`
  # list and watch paths; a `namespaces/{namespace}` path decides.
  testScopeFromPaths = {
    expr = summary (loadKubernetes {
      openapi = [ pathsDoc ];
    });
    expected = [
      {
        group = "";
        version = "v1";
        kind = "Dial";
        namespaced = true;
      }
      {
        group = "";
        version = "v1";
        kind = "Knob";
        namespaced = false;
      }
      {
        group = "example.io";
        version = "v1";
        kind = "Lever";
        namespaced = false;
      }
      {
        group = "example.io";
        version = "v1";
        kind = "Switch";
        namespaced = true;
      }
    ];
  };

  testKindWithoutScopeSkipped = {
    expr = lib.any (r: r.kind == "Scale" || r.kind == "Orphan") (loadKubernetes {
      openapi = [ pathsDoc ];
    });
    expected = false;
  };

  testDiscoveryPreferredForNamedGroups = {
    expr = summary (loadKubernetes {
      openapi = [ openapi ];
      discovery = exampleDiscovery [ (resource "gizmos" "Gizmo" "Namespaced") ];
    });
    expected = [
      fixtureGadget
      (fixtureGizmo // { namespaced = true; })
    ];
  };

  testDiscoveryResponseKindGroupVersion = {
    expr = summary (loadKubernetes {
      openapi = [ openapi ];
      discovery = exampleDiscovery [
        (lib.recursiveUpdate (resource "gizmos" "Gizmo" "Namespaced") {
          responseKind = {
            group = "example.io";
            version = "v1";
          };
        })
      ];
    });
    expected = [
      fixtureGadget
      (fixtureGizmo // { namespaced = true; })
    ];
  };

  testScopeFromDiscoveryAlone = {
    expr = summary (loadKubernetes {
      openapi = [ gizmoOnlyDoc ];
      inherit discovery;
    });
    expected = [ fixtureGizmo ];
  };

  testDiscoveryIgnoredForCoreGroup = {
    expr = summary (loadKubernetes {
      openapi = [ openapi ];
      discovery = {
        items = discovery.items ++ [
          {
            metadata = { };
            versions = [
              {
                version = "v1";
                resources = [ (resource "gadgets" "Gadget" "Cluster") ];
              }
            ];
          }
        ];
      };
    });
    expected = [
      fixtureGadget
      fixtureGizmo
    ];
  };

  testNamedGroupMissingFromDiscoveryUsesPaths = {
    expr = summary (loadKubernetes {
      openapi = [ pathsDoc ];
      discovery = exampleDiscovery [ (resource "switches" "Switch" "Cluster") ];
    });
    expected = [
      {
        group = "";
        version = "v1";
        kind = "Dial";
        namespaced = true;
      }
      {
        group = "";
        version = "v1";
        kind = "Knob";
        namespaced = false;
      }
      {
        group = "example.io";
        version = "v1";
        kind = "Lever";
        namespaced = false;
      }
      {
        group = "example.io";
        version = "v1";
        kind = "Switch";
        namespaced = false;
      }
    ];
  };

  testUnknownDiscoveryScopeThrows = {
    expr = helpers.fails (loadKubernetes {
      openapi = [ openapi ];
      discovery = exampleDiscovery [ (resource "gizmos" "Gizmo" "Global") ];
    });
    expected = true;
  };

  testSchemaWithSeveralGvks = {
    expr = summary (loadKubernetes {
      openapi = [
        (doc
          {
            "/apis/example.io/v1/widgets".post = op "example.io" "v1" "Widget";
            "/apis/example.io/v2/namespaces/{namespace}/widgets".post = op "example.io" "v2" "Widget";
          }
          {
            "io.example.Widget" = kindSchema [
              (gvk "example.io" "v1" "Widget")
              (gvk "example.io" "v2" "Widget")
            ];
          }
        )
      ];
    });
    expected = [
      {
        group = "example.io";
        version = "v1";
        kind = "Widget";
        namespaced = false;
      }
      {
        group = "example.io";
        version = "v2";
        kind = "Widget";
        namespaced = true;
      }
    ];
  };

  testDuplicateAcrossDocumentsThrows = {
    expr = helpers.fails (loadKubernetes {
      openapi = [
        openapi
        openapi
      ];
      inherit discovery;
    });
    expected = true;
  };

  testDuplicateWithinDocumentThrows = {
    expr = helpers.fails (loadKubernetes {
      openapi = [
        (doc { "/apis/example.io/v1/widgets".post = op "example.io" "v1" "Widget"; } {
          "io.example.Widget" = kindSchema [ (gvk "example.io" "v1" "Widget") ];
          "io.example.WidgetCopy" = kindSchema [ (gvk "example.io" "v1" "Widget") ];
        })
      ];
    });
    expected = true;
  };

  # Shared kinds such as meta/v1 Status appear in every document but have no
  # scope, so they are skipped rather than reported as duplicates.
  testUnscopedKindsInSeveralDocuments = {
    expr =
      let
        status = {
          "io.k8s.apimachinery.pkg.apis.meta.v1.Status" = kindSchema [ (gvk "" "v1" "Status") ];
        };
      in
      kinds (loadKubernetes {
        openapi = [
          (doc { } status)
          (openapi // { components.schemas = openapi.components.schemas // status; })
        ];
        inherit discovery;
      });
    expected = [
      "Gadget"
      "Gizmo"
    ];
  };

  testNoDocumentsThrows = {
    expr = helpers.fails (loadKubernetes {
      openapi = [ ];
    });
    expected = true;
  };

  testNoResourcesThrows = {
    expr = helpers.fails (loadKubernetes {
      openapi = [
        (doc { "/api/v1/widgets".get = op "" "v1" "WidgetList"; } {
          "io.example.WidgetList" = kindSchema [ (gvk "" "v1" "WidgetList") ];
          "io.example.Orphan" = kindSchema [ (gvk "" "v1" "Orphan") ];
        })
      ];
    });
    expected = true;
  };

  testDocumentsWithoutComponentsIgnored = {
    expr = summary (loadKubernetes {
      openapi = [
        { inherit (openapi) openapi info paths; }
        openapi
      ];
      inherit discovery;
    });
    expected = [
      fixtureGadget
      fixtureGizmo
    ];
  };

  # `apis`: which group/versions get records

  testApisDefaultKeepsOnlyGaVersions = {
    expr = loadVersions { apis = "default"; };
    expected = [
      "example.io/v1"
      "example.io/v2"
      "v1"
    ];
  };

  testApisDefaultsToDefault = {
    expr = loadVersions { };
    expected = loadVersions { apis = "default"; };
  };

  testApisAllKeepsEveryVersion = {
    expr = loadVersions { apis = "all"; };
    expected = [
      "example.io/v1"
      "example.io/v2"
      "example.io/v2beta1"
      "example.io/v3alpha2"
      "v1"
      "v1alpha1"
    ];
  };

  testApisListKeepsExactlyThose = {
    expr = loadVersions {
      apis = [
        "example.io/v2beta1"
        "v1alpha1"
      ];
    };
    expected = [
      "example.io/v2beta1"
      "v1alpha1"
    ];
  };

  testApisListWithUnknownGroupVersionThrows = {
    expr = helpers.fails (loadVersions {
      apis = [
        "example.io/v1"
        "example.io/v9beta9"
      ];
    });
    expected = true;
  };

  testApisEmptyListThrows = {
    expr = helpers.fails (loadVersions {
      apis = [ ];
    });
    expected = true;
  };

  testApisUnknownValueThrows = {
    expr = helpers.fails (loadVersions {
      apis = "beta";
    });
    expected = true;
  };

  testApisDefaultWithOnlyPrereleaseVersionsThrows = {
    expr = helpers.fails (loadKubernetes {
      openapi = [
        (doc { "/api/v1alpha1/dials".get = op "" "v1alpha1" "Dial"; } {
          "io.example.Dial" = kindSchema [ (gvk "" "v1alpha1" "Dial") ];
        })
      ];
    });
    expected = true;
  };
}
