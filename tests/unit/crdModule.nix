# Unit tests for lib/crdModule.nix: the resource module for the
# CustomResourceDefinitions among already-parsed documents. Pure: the documents
# are inline Nix (tests/fixtures/crd-widget.yaml and a cluster-scoped Knob), so
# no YAML is parsed and `pkgs` is only an unforced module argument.
{
  lib,
  catenix,
  pkgs,
  helpers,
  ...
}:
let
  inherit (catenix) crdModule;

  # tests/fixtures/crd-widget.yaml: Widget, namespaced, served v1 and unserved
  # v1alpha1, plus a Namespace document to skip.
  widgetDocuments = [
    {
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
              properties = {
                apiVersion.type = "string";
                kind.type = "string";
                metadata.type = "object";
                spec = {
                  type = "object";
                  required = [ "size" ];
                  properties = {
                    size.type = "integer";
                    label.type = "string";
                    extra = {
                      type = "object";
                      x-kubernetes-preserve-unknown-fields = true;
                    };
                  };
                };
              };
            };
          }
          {
            name = "v1alpha1";
            served = false;
            storage = false;
            schema.openAPIV3Schema.type = "object";
          }
        ];
      };
    }
    {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = "not-a-crd";
    }
  ];

  # A cluster-scoped kind in the same group, with the injected fields required.
  knobDocuments = [
    {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      metadata.name = "knobs.example.com";
      spec = {
        group = "example.com";
        scope = "Cluster";
        names = {
          kind = "Knob";
          plural = "knobs";
        };
        versions = [
          {
            name = "v1";
            served = true;
            storage = true;
            schema.openAPIV3Schema = {
              type = "object";
              required = [
                "apiVersion"
                "kind"
              ];
              properties = {
                apiVersion.type = "string";
                kind.type = "string";
                metadata.type = "object";
                turns.type = "integer";
              };
            };
          }
        ];
      };
    }
  ];

  resourcesOf =
    documentLists: config:
    (helpers.eval pkgs (map crdModule documentLists ++ [ config ])).config.resources;

  # Config values as plain data: unset (null) optional fields dropped.
  plain =
    value:
    if lib.isAttrs value then
      lib.mapAttrs (_: plain) (lib.filterAttrs (_: v: v != null) value)
    else if lib.isList value then
      map plain value
    else
      value;

  rejects = documentLists: config: helpers.fails (plain (resourcesOf documentLists config));
in
{
  testDeclaresServedVersionsOnly = {
    expr = plain (resourcesOf [ widgetDocuments ] { });
    expected."example.com".v1.Widget = { };
  };

  testDeclaresScope = {
    expr =
      let
        inherit ((helpers.eval pkgs [ (crdModule (widgetDocuments ++ knobDocuments)) ]).config) kinds;
      in
      {
        widget = kinds."example.com".v1.Widget.namespaced;
        knob = kinds."example.com".v1.Knob.namespaced;
      };
    expected = {
      widget = true;
      knob = false;
    };
  };

  testTypesInstances = {
    expr = plain (
      resourcesOf [ widgetDocuments ] {
        resources."example.com".v1.Widget.small = {
          metadata.namespace = "default";
          spec = {
            size = 1;
            extra.anything.goes = true;
          };
        };
      }
    );
    expected."example.com".v1.Widget.small = {
      metadata.namespace = "default";
      spec = {
        size = 1;
        extra.anything.goes = true;
      };
    };
  };

  testWrongFieldTypeFails = {
    expr = rejects [ widgetDocuments ] { resources."example.com".v1.Widget.bad.spec.size = "big"; };
    expected = true;
  };

  testMissingRequiredFieldFails = {
    expr = rejects [ widgetDocuments ] { resources."example.com".v1.Widget.bad.spec.label = "x"; };
    expected = true;
  };

  testUnknownFieldFails = {
    expr = rejects [ widgetDocuments ] { resources."example.com".v1.Widget.bad.spec.nope = 1; };
    expected = true;
  };

  testMetadataNameCannotBeSet = {
    expr = rejects [ widgetDocuments ] {
      resources."example.com".v1.Widget.bad.metadata.name = "bad";
    };
    expected = true;
  };

  testUnservedVersionAbsent = {
    expr = rejects [ widgetDocuments ] { resources."example.com".v1alpha1.Widget.old = { }; };
    expected = true;
  };

  testClusterScopedRejectsNamespace = {
    expr = rejects [ knobDocuments ] {
      resources."example.com".v1.Knob.bad.metadata.namespace = "default";
    };
    expected = true;
  };

  testRequiredInjectedFieldsNotNeeded = {
    expr = plain (resourcesOf [ knobDocuments ] { resources."example.com".v1.Knob.k.turns = 3; });
    expected."example.com".v1.Knob.k.turns = 3;
  };

  testModulesOfSeveralDocumentListsMerge = {
    expr = plain (
      resourcesOf [ widgetDocuments knobDocuments ] {
        resources."example.com".v1 = {
          Widget.w.spec.size = 1;
          Knob.k.turns = 2;
        };
      }
    );
    expected."example.com".v1 = {
      Widget.w.spec.size = 1;
      Knob.k.turns = 2;
    };
  };

  testListDocumentsFlattened = {
    expr = plain (
      resourcesOf [
        [
          {
            apiVersion = "v1";
            kind = "List";
            items = widgetDocuments;
          }
        ]
      ] { resources."example.com".v1.Widget.w.spec.size = 1; }
    );
    expected."example.com".v1.Widget.w.spec.size = 1;
  };

  testDocumentsWithoutCrdsFail = {
    expr = rejects [
      [
        {
          apiVersion = "v1";
          kind = "Namespace";
        }
      ]
    ] { };
    expected = true;
  };

  testNoDocumentsFail = {
    expr = rejects [ [ ] ] { };
    expected = true;
  };
}
