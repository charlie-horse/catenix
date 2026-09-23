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

  # Three OpenAPI documents (core Gadget, example.io/v1 Gizmo scoped only by
  # discovery, example.io/v1beta1 Gizmo), one without `components`, a non-JSON
  # file, and discovery.
  fakeSrc = fixtures + "/kubernetes-src";

  # The same tree without `api/discovery`.
  noDiscoverySrc = builtins.path {
    name = "kubernetes-src-no-discovery";
    path = fakeSrc;
    filter = path: _: baseNameOf path != "discovery";
  };

  resourcesOf = src: resourcesWith [ { kubernetesSrc = src; } ];

  # Resources of one `mkKubernetesModule` per argument set, plus `config`.
  resourcesWith =
    argsList: config:
    (helpers.eval pkgs (map mkKubernetesModule argsList ++ [ config ])).config.resources;

  # "group/version" of every declared version ("v1" for core).
  groupVersionsOf =
    resources:
    lib.sort lib.lessThan (
      lib.concatMap (
        group:
        map (version: if group == "core" then version else "${group}/${version}") (
          lib.attrNames resources.${group}
        )
      ) (lib.attrNames resources)
    );

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

  testApisDefaultSkipsBetaVersion = {
    expr = groupVersionsOf (resourcesOf fakeSrc { });
    expected = [
      "example.io/v1"
      "v1"
    ];
  };

  testApisAllDeclaresBetaVersion = {
    expr = plain (
      resourcesWith [
        {
          kubernetesSrc = fakeSrc;
          apis = "all";
        }
      ] { resources."example.io".v1beta1.Gizmo.z.weight = 0.5; }
    );
    expected = fakeKinds // {
      "example.io" = fakeKinds."example.io" // {
        v1beta1.Gizmo.z.weight = 0.5;
      };
    };
  };

  # A second module with just the extra group/versions composes with the
  # default one, as it would with `nixosModules.default`.
  testApisListAlongsideDefault = {
    expr = groupVersionsOf (
      resourcesWith [
        { kubernetesSrc = fakeSrc; }
        {
          kubernetesSrc = fakeSrc;
          apis = [ "example.io/v1beta1" ];
        }
      ] { }
    );
    expected = [
      "example.io/v1"
      "example.io/v1beta1"
      "v1"
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

  # Exactly the built-in group/versions a default k3s v1.37 server listed in
  # a smoke test (its CRD groups left out).
  testRealSpecDefaultMatchesServedGroupVersions = {
    expr = groupVersionsOf (resourcesOf kubernetesSrc { });
    expected = [
      "admissionregistration.k8s.io/v1"
      "apiextensions.k8s.io/v1"
      "apiregistration.k8s.io/v1"
      "apps/v1"
      "authentication.k8s.io/v1"
      "authorization.k8s.io/v1"
      "autoscaling/v1"
      "autoscaling/v2"
      "batch/v1"
      "certificates.k8s.io/v1"
      "coordination.k8s.io/v1"
      "discovery.k8s.io/v1"
      "events.k8s.io/v1"
      "flowcontrol.apiserver.k8s.io/v1"
      "networking.k8s.io/v1"
      "node.k8s.io/v1"
      "policy/v1"
      "rbac.authorization.k8s.io/v1"
      "resource.k8s.io/v1"
      "scheduling.k8s.io/v1"
      "storage.k8s.io/v1"
      "storagemigration.k8s.io/v1"
      "v1"
    ];
  };

  testRealSpecPrereleaseKindsOnlyWithAll = {
    expr =
      let
        has = resources: path: lib.hasAttrByPath path resources;
        default = resourcesOf kubernetesSrc { };
        all = resourcesWith [
          {
            inherit kubernetesSrc;
            apis = "all";
          }
        ] { };
        paths = [
          [
            "apps"
            "v1"
            "Deployment"
          ]
          [
            "coordination.k8s.io"
            "v1"
            "Lease"
          ]
          [
            "coordination.k8s.io"
            "v1beta1"
            "LeaseCandidate"
          ]
          [
            "resource.k8s.io"
            "v1beta2"
            "ResourceClaim"
          ]
        ];
      in
      {
        default = map (has default) paths;
        all = map (has all) paths;
      };
    expected = {
      default = [
        true
        true
        false
        false
      ];
      all = [
        true
        true
        true
        true
      ];
    };
  };

  testRealSpecExtraApisAlongsideDefault = {
    expr =
      plain
        (resourcesWith
          [
            { inherit kubernetesSrc; }
            {
              inherit kubernetesSrc;
              apis = [ "coordination.k8s.io/v1beta1" ];
            }
          ]
          {
            resources."coordination.k8s.io".v1beta1.LeaseCandidate.lc = {
              metadata.namespace = "default";
              spec = {
                leaseName = "lease";
                binaryVersion = "1.37.0";
                strategy = "OldestEmulationVersion";
              };
            };
          }
        )."coordination.k8s.io".v1beta1.LeaseCandidate;
    expected.lc = {
      metadata.namespace = "default";
      spec = {
        leaseName = "lease";
        binaryVersion = "1.37.0";
        strategy = "OldestEmulationVersion";
      };
    };
  };
}
