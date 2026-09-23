# Unit tests for lib/mkKubernetesModule.nix: the resource module of a
# Kubernetes source tree. Mostly a fake tree (tests/fixtures/kubernetes-src),
# plus a light check of the real pinned source.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  helpers,
  kubernetesSrc,
  ...
}:
let
  inherit (catenix) mkKubernetesModule;

  # Two OpenAPI documents (core Gadget, example.io Gizmo scoped only by
  # discovery), one without `components`, a non-JSON file, and discovery.
  fakeSrc = fixtures + "/kubernetes-src";

  # The same tree without `api/discovery`.
  noDiscoverySrc = builtins.path {
    name = "kubernetes-src-no-discovery";
    path = fakeSrc;
    filter = path: _: baseNameOf path != "discovery";
  };

  resourcesOf =
    src: config:
    (helpers.eval pkgs [
      (mkKubernetesModule { kubernetesSrc = src; })
      config
    ]).config.resources;

  # Config values as plain data: unset (null) optional fields dropped.
  plain =
    value:
    if lib.isAttrs value then
      lib.mapAttrs (_: plain) (lib.filterAttrs (_: v: v != null) value)
    else if lib.isList value then
      map plain value
    else
      value;

  rejects = src: config: helpers.fails (plain (resourcesOf src config));

  fakeKinds = {
    core.v1.Gadget = { };
    "example.io".v1.Gizmo = { };
  };
in
{
  # A fake source tree

  testDeclaresKindsOfEveryDocument = {
    expr = plain (resourcesOf fakeSrc { });
    expected = fakeKinds;
  };

  testWithoutDiscoverySkipsKindsItScopes = {
    expr = plain (resourcesOf noDiscoverySrc { });
    expected.core.v1.Gadget = { };
  };

  testTypesInstances = {
    expr = plain (
      resourcesOf fakeSrc {
        resources.core.v1.Gadget.g = {
          metadata.namespace = "default";
          spec.size = 2;
        };
        resources."example.io".v1.Gizmo.z.weight = 0.5;
      }
    );
    expected = {
      core.v1.Gadget.g = {
        metadata.namespace = "default";
        spec.size = 2;
      };
      "example.io".v1.Gizmo.z.weight = 0.5;
    };
  };

  testWrongFieldTypeFails = {
    expr = rejects fakeSrc { resources.core.v1.Gadget.bad.spec.size = "two"; };
    expected = true;
  };

  testDiscoveryScopeApplies = {
    expr = rejects fakeSrc { resources."example.io".v1.Gizmo.bad.metadata.namespace = "default"; };
    expected = true;
  };

  testAcceptsStringAndFlakeInputSources = {
    expr = map (src: plain (resourcesOf src { })) [
      "${fakeSrc}"
      { outPath = "${fakeSrc}"; }
    ];
    expected = [
      fakeKinds
      fakeKinds
    ];
  };

  testSourceWithoutSpecFails = {
    expr = rejects fixtures { };
    expected = true;
  };

  # The real pinned source

  testRealSpecConfigMap = {
    expr =
      plain
        (resourcesOf kubernetesSrc {
          resources.core.v1.ConfigMap.settings = {
            metadata.namespace = "default";
            data."app.conf" = "debug = true";
          };
        }).core.v1.ConfigMap;
    expected.settings = {
      metadata.namespace = "default";
      data."app.conf" = "debug = true";
    };
  };

  testRealSpecDeclaresKnownKinds = {
    expr =
      let
        resources = resourcesOf kubernetesSrc { };
      in
      map (path: lib.hasAttrByPath path resources) [
        [
          "apps"
          "v1"
          "Deployment"
        ]
        [
          "rbac.authorization.k8s.io"
          "v1"
          "ClusterRole"
        ]
        [
          "core"
          "v1"
          "ConfigMapList"
        ]
      ];
    expected = [
      true
      true
      false
    ];
  };

  testRealSpecClusterScopedKindRejectsNamespace = {
    expr = rejects kubernetesSrc { resources.core.v1.Namespace.bad.metadata.namespace = "default"; };
    expected = true;
  };
}
