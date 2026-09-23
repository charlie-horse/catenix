# Fixture-driven: a module built from the fake OpenAPI spec, composed with the
# resource/build modules, declaring resources end to end.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  helpers,
  ...
}:
let
  kubernetesModule = catenix.resourceModule.mkResourceModule (
    catenix.kubernetes.loadKubernetes {
      openapi = [ (lib.importJSON "${fixtures}/openapi-minimal.json") ];
      discovery = lib.importJSON "${fixtures}/discovery-minimal.json";
    }
  );

  eval =
    modules:
    helpers.eval pkgs (
      [
        ../../modules/resources.nix
        ../../modules/build.nix
        kubernetesModule
      ]
      ++ modules
    );

  valid = eval [
    {
      resources.core.v1.Gadget.my-gadget = {
        metadata.namespace = "default";
        metadata.labels.app = "demo";
        spec = {
          size = 3;
          port = "http";
        };
      };
      resources."example.io".v1.Gizmo.heavy.weight = 2.5;
    }
  ];
in
{
  testManifests = {
    expr = valid.config.build.manifests;
    expected = [
      {
        apiVersion = "v1";
        kind = "Gadget";
        metadata = {
          name = "my-gadget";
          namespace = "default";
          labels.app = "demo";
        };
        spec = {
          size = 3;
          port = "http";
        };
      }
      {
        apiVersion = "example.io/v1";
        kind = "Gizmo";
        metadata.name = "heavy";
        weight = 2.5;
      }
    ];
  };

  testYaml = {
    expr = builtins.readFile valid.config.build.yaml;
    expected = ''
      apiVersion: v1
      kind: Gadget
      metadata:
        labels:
          app: demo
        name: my-gadget
        namespace: default
      spec:
        port: http
        size: 3
      ---
      apiVersion: example.io/v1
      kind: Gizmo
      metadata:
        name: heavy
      weight: 2.5
    '';
  };

  testWrongFieldTypeFails = {
    expr =
      helpers.fails
        (eval [ { resources.core.v1.Gadget.bad.spec.size = "three"; } ]).config.build.manifests;
    expected = true;
  };

  testMissingRequiredFieldFails = {
    expr =
      helpers.fails
        (eval [ { resources.core.v1.Gadget.bad.spec.color = "red"; } ]).config.build.manifests;
    expected = true;
  };

  testClusterScopedRejectsNamespace = {
    expr =
      helpers.fails
        (eval [ { resources."example.io".v1.Gizmo.bad.metadata.namespace = "default"; } ])
        .config.build.manifests;
    expected = true;
  };

  testUnknownKindAllowedByDefault = {
    expr = (eval [ { resources.core.v1.Unknown.thing.anything = 1; } ]).config.build.manifests;
    expected = [
      {
        apiVersion = "v1";
        kind = "Unknown";
        metadata.name = "thing";
        anything = 1;
      }
    ];
  };

  testUnknownKindRejectedWhenStrict = {
    expr =
      helpers.fails
        (eval [
          {
            validation.strict = true;
            resources.core.v1.Unknown.thing.anything = 1;
          }
        ]).config.build.manifests;
    expected = true;
  };
}
