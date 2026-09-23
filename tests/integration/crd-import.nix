# Fixture-driven: a CRD imported from YAML, composed with the resource/build
# modules, declaring a custom resource end to end.
{
  catenix,
  pkgs,
  fixtures,
  helpers,
  ...
}:
let
  eval =
    modules:
    helpers.eval pkgs (
      [
        ../../modules/resources.nix
        ../../modules/build.nix
        (catenix.importCrdModule {
          inherit pkgs;
          crdFile = "${fixtures}/crd-widget.yaml";
        })
      ]
      ++ modules
    );

  valid = eval [
    {
      resources."example.com".v1.Widget.small = {
        metadata.namespace = "default";
        spec = {
          size = 1;
          extra.anything.goes = true;
        };
      };
    }
  ];
in
{
  testManifests = {
    expr = valid.config.build.manifests;
    expected = [
      {
        apiVersion = "example.com/v1";
        kind = "Widget";
        metadata = {
          name = "small";
          namespace = "default";
        };
        spec = {
          size = 1;
          extra.anything.goes = true;
        };
      }
    ];
  };

  testYaml = {
    expr = builtins.readFile valid.config.build.yaml;
    expected = ''
      apiVersion: example.com/v1
      kind: Widget
      metadata:
        name: small
        namespace: default
      spec:
        extra:
          anything:
            goes: true
        size: 1
    '';
  };

  testMissingRequiredFieldFails = {
    expr =
      helpers.fails
        (eval [ { resources."example.com".v1.Widget.bad.spec.label = "x"; } ]).config.build.manifests;
    expected = true;
  };

  testWrongFieldTypeFails = {
    expr =
      helpers.fails
        (eval [ { resources."example.com".v1.Widget.bad.spec.size = "big"; } ]).config.build.manifests;
    expected = true;
  };

  testUnservedVersionAbsent = {
    expr =
      helpers.fails
        (eval [
          {
            validation.strict = true;
            resources."example.com".v1alpha1.Widget.old = { };
          }
        ]).config.build.manifests;
    expected = true;
  };
}
