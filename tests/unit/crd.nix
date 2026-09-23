# Unit tests for lib/crd.nix: CustomResourceDefinition documents -> resource
# schema records. Documents are written inline, as `yaml2json` would parse them.
{
  catenix,
  helpers,
  ...
}:
let
  inherit (catenix.crd) loadCrds;

  failsOn = documents: helpers.fails (loadCrds documents);

  widgetSchema = {
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

  widgetV1Version = {
    name = "v1";
    served = true;
    storage = true;
    schema.openAPIV3Schema = widgetSchema;
  };

  # The documents of tests/fixtures/crd-widget.yaml.
  widget = {
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
        widgetV1Version
        {
          name = "v1alpha1";
          served = false;
          storage = false;
          schema.openAPIV3Schema.type = "object";
        }
      ];
    };
  };
  namespace = {
    apiVersion = "v1";
    kind = "Namespace";
    metadata.name = "not-a-crd";
  };

  widgetV1 = {
    group = "example.com";
    version = "v1";
    kind = "Widget";
    namespaced = true;
    schema = widgetSchema;
    definitions = { };
  };

  # A cluster-scoped CRD serving two versions.
  gadgetSchema = version: {
    type = "object";
    description = "Gadget ${version}";
  };
  gadget = {
    apiVersion = "apiextensions.k8s.io/v1";
    kind = "CustomResourceDefinition";
    metadata.name = "gadgets.example.org";
    spec = {
      group = "example.org";
      scope = "Cluster";
      names = {
        kind = "Gadget";
        plural = "gadgets";
      };
      versions = [
        {
          name = "v1beta1";
          served = true;
          storage = false;
          schema.openAPIV3Schema = gadgetSchema "v1beta1";
        }
        {
          name = "v1";
          served = true;
          storage = true;
          schema.openAPIV3Schema = gadgetSchema "v1";
        }
      ];
    };
  };
  gadgetRecord = version: {
    group = "example.org";
    inherit version;
    kind = "Gadget";
    namespaced = false;
    schema = gadgetSchema version;
    definitions = { };
  };

  # `widget` with some `spec` attributes replaced, or removed.
  widgetWith = spec: widget // { spec = widget.spec // spec; };
  widgetWithout = names: widget // { spec = removeAttrs widget.spec names; };

  # `widget` serving only v1, with some of its attributes replaced, or removed.
  widgetV1With = attrs: widgetWith { versions = [ (widgetV1Version // attrs) ]; };
  widgetV1Without = names: widgetWith { versions = [ (removeAttrs widgetV1Version names) ]; };
in
{
  # Valid input.

  testFixtureDocuments = {
    expr = loadCrds [
      widget
      namespace
    ];
    expected = [ widgetV1 ];
  };

  testUnservedVersionsDropped = {
    expr = map (record: record.version) (loadCrds [ widget ]);
    expected = [ "v1" ];
  };

  testMultipleServedVersions = {
    expr = loadCrds [ gadget ];
    expected = [
      (gadgetRecord "v1beta1")
      (gadgetRecord "v1")
    ];
  };

  testClusterScope = {
    expr = loadCrds [ (widgetWith { scope = "Cluster"; }) ];
    expected = [ (widgetV1 // { namespaced = false; }) ];
  };

  testMultipleCrds = {
    expr = loadCrds [
      widget
      gadget
    ];
    expected = [
      widgetV1
      (gadgetRecord "v1beta1")
      (gadgetRecord "v1")
    ];
  };

  testListFlattened = {
    expr = loadCrds [
      {
        apiVersion = "v1";
        kind = "List";
        items = [
          widget
          namespace
        ];
      }
    ];
    expected = [ widgetV1 ];
  };

  testCrdListFlattened = {
    expr = loadCrds [
      {
        apiVersion = "apiextensions.k8s.io/v1";
        kind = "CustomResourceDefinitionList";
        items = [
          widget
          gadget
        ];
      }
    ];
    expected = [
      widgetV1
      (gadgetRecord "v1beta1")
      (gadgetRecord "v1")
    ];
  };

  testNonCrdDocumentsSkipped = {
    expr = loadCrds [
      namespace
      widget
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata.name = "also-not-a-crd";
        data.key = "value";
      }
    ];
    expected = [ widgetV1 ];
  };

  testNullDocumentsSkipped = {
    expr = loadCrds [
      null
      widget
      null
    ];
    expected = [ widgetV1 ];
  };

  testPreserveUnknownFieldsFalseAccepted = {
    expr = loadCrds [ (widgetWith { preserveUnknownFields = false; }) ];
    expected = [ widgetV1 ];
  };

  # Invalid CRDs.

  testWrongApiVersionFails = {
    expr = failsOn [ (widget // { apiVersion = "apiextensions.k8s.io/v1beta1"; }) ];
    expected = true;
  };

  testMissingApiVersionFails = {
    expr = failsOn [ (removeAttrs widget [ "apiVersion" ]) ];
    expected = true;
  };

  testPreserveUnknownFieldsFails = {
    expr = failsOn [ (widgetWith { preserveUnknownFields = true; }) ];
    expected = true;
  };

  testMissingSpecFails = {
    expr = failsOn [ (removeAttrs widget [ "spec" ]) ];
    expected = true;
  };

  testEmptyGroupFails = {
    expr = failsOn [ (widgetWith { group = ""; }) ];
    expected = true;
  };

  testMissingGroupFails = {
    expr = failsOn [ (widgetWithout [ "group" ]) ];
    expected = true;
  };

  testEmptyKindFails = {
    expr = failsOn [
      (widgetWith {
        names = widget.spec.names // {
          kind = "";
        };
      })
    ];
    expected = true;
  };

  testMissingKindFails = {
    expr = failsOn [ (widgetWith { names.plural = "widgets"; }) ];
    expected = true;
  };

  testEmptyScopeFails = {
    expr = failsOn [ (widgetWith { scope = ""; }) ];
    expected = true;
  };

  testMissingScopeFails = {
    expr = failsOn [ (widgetWithout [ "scope" ]) ];
    expected = true;
  };

  testUnknownScopeFails = {
    expr = failsOn [ (widgetWith { scope = "namespaced"; }) ];
    expected = true;
  };

  testEmptyVersionsFails = {
    expr = failsOn [ (widgetWith { versions = [ ]; }) ];
    expected = true;
  };

  testMissingVersionsFails = {
    expr = failsOn [ (widgetWithout [ "versions" ]) ];
    expected = true;
  };

  testMissingVersionNameFails = {
    expr = failsOn [ (widgetV1Without [ "name" ]) ];
    expected = true;
  };

  testMissingServedFails = {
    expr = failsOn [ (widgetV1Without [ "served" ]) ];
    expected = true;
  };

  testNonBooleanServedFails = {
    expr = failsOn [ (widgetV1With { served = "true"; }) ];
    expected = true;
  };

  testMissingSchemaFails = {
    expr = failsOn [ (widgetV1Without [ "schema" ]) ];
    expected = true;
  };

  testMissingOpenAPIV3SchemaFails = {
    expr = failsOn [ (widgetV1With { schema = { }; }) ];
    expected = true;
  };

  testNonObjectSchemaFails = {
    expr = failsOn [ (widgetV1With { schema.openAPIV3Schema = "object"; }) ];
    expected = true;
  };

  testUnservedVersionValidated = {
    expr = failsOn [
      (widgetWith {
        versions = [
          widgetV1Version
          {
            name = "v1alpha1";
            served = false;
          }
        ];
      })
    ];
    expected = true;
  };

  testNoServedVersionsFails = {
    expr = failsOn [ (widgetV1With { served = false; }) ];
    expected = true;
  };

  # Invalid document sets.

  testDuplicateCrdFails = {
    expr = failsOn [
      widget
      widget
    ];
    expected = true;
  };

  testDuplicateResourceAcrossCrdsFails = {
    expr = failsOn [
      widget
      (widget // { metadata.name = "widgets-again.example.com"; })
    ];
    expected = true;
  };

  testDuplicateVersionFails = {
    expr = failsOn [
      (widgetWith {
        versions = [
          widgetV1Version
          widgetV1Version
        ];
      })
    ];
    expected = true;
  };

  testNoCrdsFails = {
    expr = failsOn [ namespace ];
    expected = true;
  };

  testNoDocumentsFails = {
    expr = failsOn [ ];
    expected = true;
  };
}
