# Unit tests for lib/chartModule.nix: an already-rendered Helm chart (its
# manifest list) as a module — patched, its CRDs typing its custom resources,
# and every object defined through `manifestsToResources`. System-agnostic:
# the manifests are the recording of what `helmTemplate` renders for
# tests/fixtures/charts/demo as release `rel` in `apps` (checked against helm
# by tests/per-system.nix's `contracts.demo-rel`), and `pkgs` is only an
# unforced module argument. This also covers `importChart`, which is this over
# `helmTemplate` (tests/unit/importChart.nix checks that wiring).
{
  lib,
  catenix,
  pkgs,
  helpers,
  recorded,
  catenixModule,
  ...
}:
let
  # What `helmTemplate` renders for tests/fixtures/charts/demo as release
  # `rel` in `apps` (recorded), in `helm template`'s order.
  demoManifests = recorded "demo-rel";

  labels = {
    "app.kubernetes.io/name" = "demo";
    "app.kubernetes.io/instance" = "rel";
  };

  widgetCrd = lib.findFirst (m: m.kind == "CustomResourceDefinition") null demoManifests;

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
