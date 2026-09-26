# A real published chart: cert-manager v1.21.2 (the `cert-manager-chart`
# flake input, the chart repository's .tgz), with its CRDs rendered from
# templates (`crds.enabled`), imported into `nixosModules.default` in strict
# mode. Every rendered object must type-check against the pinned Kubernetes
# spec and the chart's own CRDs, and `build.yaml` must build.
#
# `agnostic` cases are system-agnostic (tests/agnostic.nix): helm's full render
# comes recorded (checked by `contracts.cert-manager`) through `chartModule`,
# the core of `importChart`. `rendering` reads `build.yaml` back, so it runs
# per system (tests/per-system.nix).
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
  eval =
    modules:
    helpers.eval pkgs (
      [
        catenixModule
        { validation.strict = true; }
        (catenix.chartModule {
          manifests = recorded "cert-manager";
          release = {
            name = "cert-manager";
            namespace = "cert-manager";
          };
          chartName = "cert-manager";
        })
        { resources.core.v1.Namespace.cert-manager = { }; }
      ]
      ++ modules
    );

  manifestsOf = modules: (eval modules).config.build.manifests;

  # A custom resource of a kind the chart's CRDs define.
  issuer = spec: { resources."cert-manager.io".v1.ClusterIssuer.self-signed = { inherit spec; }; };

  kindCounts = manifests: lib.mapAttrs (_: lib.length) (lib.groupBy (m: m.kind) manifests);
in
{
  agnostic = {
    testKinds = {
      expr = kindCounts (manifestsOf [ ]);
      expected = {
        ClusterRole = 13;
        ClusterRoleBinding = 10;
        CustomResourceDefinition = 6;
        Deployment = 3;
        Job = 1;
        MutatingWebhookConfiguration = 1;
        Namespace = 1;
        Role = 4;
        RoleBinding = 4;
        Service = 3;
        ServiceAccount = 4;
        ValidatingWebhookConfiguration = 1;
      };
    };

    # Leader election lives in kube-system; everything else in the release's
    # namespace, filled in by Helm's templates or by importChart.
    testNamespaces = {
      expr = lib.unique (
        lib.sort lib.lessThan (
          lib.concatMap (m: lib.toList (m.metadata.namespace or [ ])) (manifestsOf [ ])
        )
      );
      expected = [
        "cert-manager"
        "kube-system"
      ];
    };

    testChartCrdsDeclareKinds = {
      expr = lib.attrNames (eval [ ]).config.kinds."cert-manager.io".v1;
      expected = [
        "Certificate"
        "CertificateRequest"
        "ClusterIssuer"
        "Issuer"
      ];
    };

    testOverride = {
      expr =
        (lib.findFirst (m: m.kind == "Deployment" && m.metadata.name == "cert-manager") null (manifestsOf [
          { resources.apps.v1.Deployment.cert-manager.spec.replicas = 2; }
        ])).spec.replicas;
      expected = 2;
    };

    testCustomResourceTypedByChartCrd = {
      expr = map (spec: helpers.fails (manifestsOf [ (issuer spec) ])) [
        { selfSigned = { }; }
        { selfSigned.crlDistributionPoints = "http://example.com/crl"; }
        { selfSighned = { }; }
      ];
      expected = [
        false
        true
        true
      ];
    };
  };

  # Byte-level `build.yaml`, read back: per-system (tests/per-system.nix).
  rendering = {
    testYaml = {
      expr =
        lib.hasPrefix
          "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: cert-manager\n---\napiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\n"
          (builtins.readFile (eval [ ]).config.build.yaml);
      expected = true;
    };
  };
}
