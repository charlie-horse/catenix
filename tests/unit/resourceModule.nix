# Unit tests for lib/resourceModule.nix: resource schema records -> a module
# declaring `resources.<group>.<version>.<Kind>.<name>`, checked behaviourally
# with `lib.evalModules`, plus direct tests of `instanceType`.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  helpers,
  ...
}:
let
  inherit (catenix.resourceModule) mkResourceModule instanceType;

  definitions = (lib.importJSON "${fixtures}/openapi-minimal.json").components.schemas;

  # A namespaced core-group kind with typed (ObjectMeta) metadata.
  gadget = {
    group = "";
    version = "v1";
    kind = "Gadget";
    namespaced = true;
    schema = definitions."io.example.Gadget";
    inherit definitions;
  };

  # A cluster-scoped named-group kind with typed metadata.
  gizmo = {
    group = "example.io";
    version = "v1";
    kind = "Gizmo";
    namespaced = false;
    schema = definitions."io.example.Gizmo";
    inherit definitions;
  };

  # CRD-style kinds: `metadata` is a bare `type: object`, no definitions.
  crdKind = kind: namespaced: {
    group = "example.com";
    version = "v1";
    inherit kind namespaced;
    schema = {
      type = "object";
      properties = {
        apiVersion.type = "string";
        kind.type = "string";
        metadata.type = "object";
        spec = {
          type = "object";
          required = [ "size" ];
          properties.size.type = "integer";
        };
      };
    };
    definitions = { };
  };
  widget = crdKind "Widget" true;
  knob = crdKind "Knob" false;

  # A kind that keeps unknown fields and declares no properties at all.
  blob = {
    group = "example.com";
    version = "v1";
    kind = "Blob";
    namespaced = true;
    schema = {
      type = "object";
      x-kubernetes-preserve-unknown-fields = true;
    };
    definitions = { };
  };

  # A kind with properties but no `metadata` property.
  bare = {
    group = "example.com";
    version = "v1";
    kind = "Bare";
    namespaced = true;
    schema = {
      type = "object";
      properties.spec.type = "string";
    };
    definitions = { };
  };

  # A kind that lists the injected fields as required.
  strict = {
    group = "example.com";
    version = "v1";
    kind = "Strict";
    namespaced = false;
    schema = {
      type = "object";
      required = [
        "apiVersion"
        "kind"
        "spec"
      ];
      properties = {
        apiVersion.type = "string";
        kind.type = "string";
        metadata = {
          type = "object";
          required = [
            "name"
            "namespace"
          ];
          properties = {
            name.type = "string";
            namespace.type = "string";
            uid.type = "string";
          };
        };
        spec.type = "string";
      };
    };
    definitions = { };
  };

  # A kind whose nested schemas must not be forced unless it is used. (The
  # module system does look at each kind's top-level schema, to learn that
  # its instances are submodules.)
  broken = {
    group = "example.com";
    version = "v1";
    kind = "Broken";
    namespaced = true;
    schema = {
      type = "object";
      properties = {
        metadata = throw "the Broken metadata schema was forced";
        spec = throw "the Broken spec schema was forced";
      };
    };
    definitions = throw "the Broken definitions were forced";
  };

  # A stand-in for modules/resources.nix: accepts unknown groups/kinds.
  freeformResources = {
    options.resources = lib.mkOption {
      type = lib.types.submodule {
        freeformType = with lib.types; attrsOf (attrsOf (attrsOf (attrsOf (attrsOf anything))));
      };
      default = { };
    };
  };

  eval = modules: helpers.eval pkgs modules;
  resourcesOf =
    records: config:
    (eval [
      (mkResourceModule records)
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

  # Whether evaluating `config` against `records` fails.
  rejects = records: config: helpers.fails (plain (resourcesOf records config));

  # Merges `value` into an option of type `type`.
  evalType =
    type: value:
    (lib.evalModules {
      modules = [
        { options.x = lib.mkOption { inherit type; }; }
        { x = value; }
      ];
    }).config.x;

  subOptionNames = type: lib.attrNames (removeAttrs (type.getSubOptions [ ]) [ "_module" ]);
in
{
  # mkResourceModule: layout

  testKindsDefaultToEmpty = {
    expr = plain (resourcesOf [ gadget gizmo ] { });
    expected = {
      core.v1.Gadget = { };
      "example.io".v1.Gizmo = { };
    };
  };

  testDeclaresInstances = {
    expr = plain (
      resourcesOf [ gadget gizmo ] {
        resources.core.v1.Gadget.my-gadget = {
          metadata.namespace = "default";
          metadata.labels.app = "demo";
          spec = {
            size = 3;
            port = "http";
            children = [ { size = 1; } ];
          };
        };
        resources."example.io".v1.Gizmo.heavy.weight = 2.5;
      }
    );
    expected = {
      core.v1.Gadget.my-gadget = {
        metadata = {
          namespace = "default";
          labels.app = "demo";
        };
        spec = {
          size = 3;
          port = "http";
          children = [ { size = 1; } ];
        };
      };
      "example.io".v1.Gizmo.heavy.weight = 2.5;
    };
  };

  testUnsetOptionalFieldsAreNull = {
    expr = (resourcesOf [ gadget ] { resources.core.v1.Gadget.g = { }; }).core.v1.Gadget.g;
    expected = {
      enabled = null;
      metadata = null;
      spec = null;
    };
  };

  testKindOptionCarriesDescription = {
    expr =
      let
        options = (eval [ (mkResourceModule [ gadget ]) ]).options.resources.type.getSubOptions [ ];
      in
      options.core.v1.Gadget.description;
    expected = "A namespaced core-group test kind.";
  };

  # mkResourceModule: typing

  testWrongFieldTypeFails = {
    expr = rejects [ gadget ] { resources.core.v1.Gadget.bad.spec.size = "three"; };
    expected = true;
  };

  testMissingRequiredFieldFails = {
    expr = rejects [ gadget ] { resources.core.v1.Gadget.bad.spec.color = "red"; };
    expected = true;
  };

  testUnknownFieldFails = {
    expr = rejects [ gadget ] { resources.core.v1.Gadget.bad.nope = 1; };
    expected = true;
  };

  testUnknownNestedFieldFails = {
    expr = rejects [ gadget ] {
      resources.core.v1.Gadget.bad.spec = {
        size = 1;
        nope = 1;
      };
    };
    expected = true;
  };

  testUnknownKindFails = {
    expr = rejects [ gadget ] { resources.core.v1.Nope.x = { }; };
    expected = true;
  };

  testApiVersionCannotBeSet = {
    expr = rejects [ gadget ] { resources.core.v1.Gadget.bad.apiVersion = "v1"; };
    expected = true;
  };

  testKindCannotBeSet = {
    expr = rejects [ gadget ] { resources.core.v1.Gadget.bad.kind = "Gadget"; };
    expected = true;
  };

  testMetadataNameCannotBeSet = {
    expr = rejects [ gadget ] { resources.core.v1.Gadget.bad.metadata.name = "bad"; };
    expected = true;
  };

  testClusterScopedRejectsNamespace = {
    expr = rejects [ gizmo ] { resources."example.io".v1.Gizmo.bad.metadata.namespace = "default"; };
    expected = true;
  };

  testClusterScopedAcceptsOtherMetadata = {
    expr = plain (
      resourcesOf [ gizmo ] { resources."example.io".v1.Gizmo.ok.metadata.labels.tier = "db"; }
    );
    expected."example.io".v1.Gizmo.ok.metadata.labels.tier = "db";
  };

  testInjectedFieldsDroppedFromRequired = {
    expr = plain (
      resourcesOf [ strict ] {
        resources."example.com".v1.Strict.ok = {
          metadata.uid = "1234";
          spec = "x";
        };
      }
    );
    expected."example.com".v1.Strict.ok = {
      metadata.uid = "1234";
      spec = "x";
    };
  };

  testOtherRequiredFieldsStayRequired = {
    expr = rejects [ strict ] { resources."example.com".v1.Strict.bad.metadata.uid = "1234"; };
    expected = true;
  };

  # mkResourceModule: kinds whose objects accept unknown fields

  testUntypedMetadataAcceptsAnyField = {
    expr = plain (
      resourcesOf [ widget ] {
        resources."example.com".v1.Widget.w = {
          metadata = {
            namespace = "default";
            annotations."example.com/note" = "hi";
          };
          spec.size = 1;
        };
      }
    );
    expected."example.com".v1.Widget.w = {
      metadata = {
        namespace = "default";
        annotations."example.com/note" = "hi";
      };
      spec.size = 1;
    };
  };

  testUntypedMetadataRejectsName = {
    expr = rejects [ widget ] { resources."example.com".v1.Widget.bad.metadata.name = "bad"; };
    expected = true;
  };

  testUntypedMetadataClusterScopedRejectsNamespace = {
    expr = rejects [ knob ] { resources."example.com".v1.Knob.bad.metadata.namespace = "default"; };
    expected = true;
  };

  testUntypedMetadataClusterScopedAcceptsLabels = {
    expr = plain (resourcesOf [ knob ] { resources."example.com".v1.Knob.k.metadata.labels.a = "b"; });
    expected."example.com".v1.Knob.k.metadata.labels.a = "b";
  };

  testPreserveUnknownKindAcceptsAnyField = {
    expr = plain (
      resourcesOf [ blob ] {
        resources."example.com".v1.Blob.b = {
          metadata.namespace = "default";
          data.anything = [ 1 ];
        };
      }
    );
    expected."example.com".v1.Blob.b = {
      metadata.namespace = "default";
      data.anything = [ 1 ];
    };
  };

  testPreserveUnknownKindRejectsInjectedFields = {
    expr = map (rejects [ blob ]) [
      { resources."example.com".v1.Blob.bad.apiVersion = "example.com/v1"; }
      { resources."example.com".v1.Blob.bad.kind = "Blob"; }
      { resources."example.com".v1.Blob.bad.metadata.name = "bad"; }
    ];
    expected = [
      true
      true
      true
    ];
  };

  testKindWithoutMetadataPropertyAcceptsMetadata = {
    expr = plain (
      resourcesOf [ bare ] {
        resources."example.com".v1.Bare.b = {
          metadata.namespace = "default";
          spec = "x";
        };
      }
    );
    expected."example.com".v1.Bare.b = {
      metadata.namespace = "default";
      spec = "x";
    };
  };

  # mkResourceModule: composition

  testDuplicateKindFails = {
    expr = rejects [ gadget gadget ] { };
    expected = true;
  };

  testModulesWithDifferentGroupsMerge = {
    expr = plain (
      (eval [
        (mkResourceModule [ gadget ])
        (mkResourceModule [ gizmo ])
        {
          resources.core.v1.Gadget.g.spec.size = 1;
          resources."example.io".v1.Gizmo.z.weight = 1.5;
        }
      ]).config.resources
    );
    expected = {
      core.v1.Gadget.g.spec.size = 1;
      "example.io".v1.Gizmo.z.weight = 1.5;
    };
  };

  testModulesWithSameGroupDifferentKindsMerge = {
    expr = plain (
      (eval [
        (mkResourceModule [ widget ])
        (mkResourceModule [ knob ])
        {
          resources."example.com".v1.Widget.w.spec.size = 1;
          resources."example.com".v1.Knob.k.spec.size = 2;
        }
      ]).config.resources
    );
    expected."example.com".v1 = {
      Widget.w.spec.size = 1;
      Knob.k.spec.size = 2;
    };
  };

  testModulesDeclaringSameKindFail = {
    expr = helpers.fails (
      plain
        (eval [
          (mkResourceModule [ gadget ])
          (mkResourceModule [ gadget ])
        ]).config.resources
    );
    expected = true;
  };

  testMergesWithFreeformResourcesDeclaration = {
    expr = plain (
      (eval [
        freeformResources
        (mkResourceModule [ gadget ])
        {
          resources.core.v1.Gadget.g.spec.size = 1;
          resources.core.v1.Unknown.thing.anything = 1;
          resources.other.v2.Thing.t.x = true;
        }
      ]).config.resources
    );
    expected = {
      core.v1 = {
        Gadget.g.spec.size = 1;
        Unknown.thing.anything = 1;
      };
      other.v2.Thing.t.x = true;
    };
  };

  testFreeformResourcesStillTypesKnownKinds = {
    expr = helpers.fails (
      plain
        (eval [
          freeformResources
          (mkResourceModule [ gadget ])
          { resources.core.v1.Gadget.bad.spec.size = "three"; }
        ]).config.resources
    );
    expected = true;
  };

  testUnusedKindsNestedSchemasStayUnforced = {
    expr = plain (resourcesOf [ gadget broken ] { resources.core.v1.Gadget.g.spec.size = 1; });
    expected = {
      core.v1.Gadget.g.spec.size = 1;
      "example.com".v1.Broken = { };
    };
  };

  # instanceType

  testInstanceTypeOptions = {
    expr = subOptionNames (instanceType gadget);
    expected = [
      "enabled"
      "metadata"
      "spec"
    ];
  };

  testInstanceTypeNamespacedMetadataOptions = {
    expr = subOptionNames ((instanceType gadget).getSubOptions [ ]).metadata.type;
    expected = [
      "labels"
      "namespace"
    ];
  };

  testInstanceTypeClusterScopedMetadataOptions = {
    expr = subOptionNames ((instanceType gizmo).getSubOptions [ ]).metadata.type;
    expected = [ "labels" ];
  };

  testInstanceTypeMergesValue = {
    expr = plain (
      evalType (instanceType gadget) {
        metadata.namespace = "ns";
        spec.tags = [ "a" ];
        spec.size = 2;
      }
    );
    expected = {
      metadata.namespace = "ns";
      spec = {
        size = 2;
        tags = [ "a" ];
      };
    };
  };

  testInstanceTypeRejectsWrongType = {
    expr = helpers.fails (plain (evalType (instanceType gizmo) { weight = "heavy"; }));
    expected = true;
  };

  testInstanceTypeRejectsInjectedFields = {
    expr = map (value: helpers.fails (plain (evalType (instanceType widget) value))) [
      { apiVersion = "example.com/v1"; }
      { kind = "Widget"; }
      { metadata.name = "w"; }
    ];
    expected = [
      true
      true
      true
    ];
  };
}
