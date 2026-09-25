# Unit tests for lib/importChart.nix: a Helm chart as a module — rendered by
# `helmTemplate`, read back (import-from-derivation, so tests/flake-module.nix
# runs this suite at evaluation time), its CRDs typing its custom resources,
# and every object defined through `manifestsToResources`. The fixture chart
# is tests/fixtures/charts/demo.
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
  chart = fixtures + "/charts/demo";
  release = {
    name = "rel";
    namespace = "apps";
  };

  importDemo =
    args:
    catenix.importChart (
      {
        inherit pkgs chart release;
      }
      // args
    );

  eval =
    args: modules:
    helpers.eval pkgs (
      [
        catenixModule
        (importDemo args)
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

  testValues = {
    expr = (find "Deployment" "rel-demo" (manifestsOf { values.replicas = 4; } [ ])).spec.replicas;
    expected = 4;
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
      declared = (eval { includeCrds = false; } [ ]).config.kinds ? "example.com";
      widget = (find "Widget" "rel-demo" (manifestsOf { includeCrds = false; } [ ])).spec;
      strictFails = helpers.fails (
        manifestsOf { includeCrds = false; } [ { validation.strict = true; } ]
      );
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
}
