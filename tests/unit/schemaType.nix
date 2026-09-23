# Unit tests for lib/schemaType.nix: every row of the mapping table, checked
# behaviourally by merging values into a one-option module typed by the schema.
{
  lib,
  catenix,
  helpers,
  ...
}:
let
  inherit (catenix.schemaType) schemaType;

  # Merges `defs` (a list of definitions) into an option typed by `schema`.
  evalDefs =
    schema: defs:
    (lib.evalModules {
      modules = [
        { options.x = lib.mkOption { type = schemaType schema; }; }
      ]
      ++ map (x: { inherit x; }) defs;
    }).config.x;

  check = schema: value: evalDefs schema [ value ];
  rejects = schema: value: helpers.fails (check schema value);

  subOptions = schema: (schemaType schema).getSubOptions [ ];

  intOrString = {
    type = "string";
    x-kubernetes-int-or-string = true;
  };

  gadget = {
    type = "object";
    required = [ "size" ];
    properties = {
      size = {
        type = "integer";
        description = "How big the gadget is.";
      };
      color = {
        type = "string";
        enum = [
          "red"
          "green"
        ];
      };
    };
  };

  stringMap = {
    type = "object";
    additionalProperties.type = "string";
  };

  deployment = {
    type = "object";
    required = [ "template" ];
    properties = {
      replicas.type = "integer";
      selector = {
        type = "object";
        properties.matchLabels = stringMap;
      };
      template = {
        type = "object";
        properties.spec = {
          type = "object";
          properties.containers = {
            type = "array";
            items = {
              type = "object";
              required = [ "name" ];
              properties = {
                name = {
                  type = "string";
                  description = "Container name.";
                };
                ports = {
                  type = "array";
                  items = {
                    type = "object";
                    required = [ "containerPort" ];
                    properties = {
                      containerPort.type = "integer";
                      targetPort = intOrString;
                    };
                  };
                };
              };
            };
          };
        };
      };
    };
  };

  # A self-referential schema: infinite as a value, so only laziness lets it
  # map to a type.
  tree = {
    type = "object";
    properties = {
      name.type = "string";
      child = tree;
    };
  };
in
{
  # x-kubernetes-int-or-string

  testIntOrStringAcceptsInt = {
    expr = check intOrString 8080;
    expected = 8080;
  };

  testIntOrStringAcceptsString = {
    expr = check intOrString "http";
    expected = "http";
  };

  testIntOrStringRejectsOther = {
    expr = rejects intOrString true;
    expected = true;
  };

  # x-kubernetes-embedded-resource / x-kubernetes-preserve-unknown-fields

  testPreserveUnknownObjectAcceptsAnyAttrs = {
    expr = check {
      type = "object";
      x-kubernetes-preserve-unknown-fields = true;
    } { anything.goes = [ 1 ]; };
    expected = {
      anything.goes = [ 1 ];
    };
  };

  testPreserveUnknownObjectRejectsNonAttrs = {
    expr = rejects {
      type = "object";
      x-kubernetes-preserve-unknown-fields = true;
    } "nope";
    expected = true;
  };

  testPreserveUnknownUntypedAcceptsAnything = {
    expr = map (check { x-kubernetes-preserve-unknown-fields = true; }) [
      "s"
      [ 1 ]
      { a.b = true; }
    ];
    expected = [
      "s"
      [ 1 ]
      { a.b = true; }
    ];
  };

  testEmbeddedResourceAcceptsAnyAttrs = {
    expr = check {
      type = "object";
      x-kubernetes-embedded-resource = true;
    } { spec.containers = [ ]; };
    expected = {
      spec.containers = [ ];
    };
  };

  testEmbeddedResourceWithPropertiesChecksThem = {
    expr = rejects {
      type = "object";
      x-kubernetes-embedded-resource = true;
      properties.kind.type = "string";
    } { unknown = 1; };
    expected = true;
  };

  # enum

  testEnumAcceptsMember = {
    expr = check {
      type = "string";
      enum = [
        "TCP"
        "UDP"
      ];
    } "UDP";
    expected = "UDP";
  };

  testEnumRejectsNonMember = {
    expr = rejects {
      type = "string";
      enum = [
        "TCP"
        "UDP"
      ];
    } "SCTP";
    expected = true;
  };

  testEnumOfIntegers = {
    expr = check {
      type = "integer";
      enum = [
        1
        2
      ];
    } 2;
    expected = 2;
  };

  # oneOf / anyOf

  testOneOfAcceptsEachBranch = {
    expr =
      map
        (check {
          oneOf = [
            { type = "string"; }
            { type = "number"; }
          ];
        })
        [
          "500m"
          1.5
        ];
    expected = [
      "500m"
      1.5
    ];
  };

  testOneOfRejectsOther = {
    expr = rejects {
      oneOf = [
        { type = "string"; }
        { type = "number"; }
      ];
    } true;
    expected = true;
  };

  testAnyOfAcceptsEachBranch = {
    expr =
      map
        (check {
          anyOf = [
            { type = "integer"; }
            { type = "boolean"; }
          ];
        })
        [
          3
          false
        ];
    expected = [
      3
      false
    ];
  };

  testAnyOfRejectsOther = {
    expr = rejects {
      anyOf = [
        { type = "integer"; }
        { type = "boolean"; }
      ];
    } "3";
    expected = true;
  };

  # In structural schemas oneOf/anyOf next to a `type` only add value
  # validations (e.g. "exactly one of these is set"); the type still applies.
  testOneOfNextToTypeKeepsType = {
    expr =
      let
        schema = {
          type = "object";
          properties = {
            a.type = "string";
            b.type = "string";
          };
          oneOf = [
            { required = [ "a" ]; }
            { required = [ "b" ]; }
          ];
        };
      in
      {
        accepted = check schema { a = "x"; };
        rejected = rejects schema { a = 1; };
      };
    expected = {
      accepted = {
        a = "x";
        b = null;
      };
      rejected = true;
    };
  };

  # primitive types

  testStringAccepts = {
    expr = check { type = "string"; } "hello";
    expected = "hello";
  };

  testStringRejectsInt = {
    expr = rejects { type = "string"; } 1;
    expected = true;
  };

  testIntegerAccepts = {
    expr = check { type = "integer"; } 3;
    expected = 3;
  };

  testIntegerRejectsFloat = {
    expr = rejects { type = "integer"; } 1.5;
    expected = true;
  };

  testIntegerRejectsString = {
    expr = rejects { type = "integer"; } "3";
    expected = true;
  };

  testNumberAcceptsIntAndFloat = {
    expr = map (check { type = "number"; }) [
      2
      2.5
    ];
    expected = [
      2
      2.5
    ];
  };

  testNumberRejectsString = {
    expr = rejects { type = "number"; } "2.5";
    expected = true;
  };

  testBooleanAccepts = {
    expr = check { type = "boolean"; } false;
    expected = false;
  };

  testBooleanRejectsString = {
    expr = rejects { type = "boolean"; } "true";
    expected = true;
  };

  # arrays

  testArrayOfItems = {
    expr =
      check
        {
          type = "array";
          items.type = "string";
        }
        [
          "a"
          "b"
        ];
    expected = [
      "a"
      "b"
    ];
  };

  testArrayRejectsWrongItem = {
    expr =
      rejects
        {
          type = "array";
          items.type = "string";
        }
        [
          "a"
          1
        ];
    expected = true;
  };

  testArrayRejectsNonList = {
    expr = rejects {
      type = "array";
      items.type = "string";
    } "a";
    expected = true;
  };

  testArrayWithoutItemsAcceptsAnyElements = {
    expr = check { type = "array"; } [
      1
      "a"
      { b = true; }
    ];
    expected = [
      1
      "a"
      { b = true; }
    ];
  };

  # objects with properties

  testObjectOptionalAbsentIsNull = {
    expr = check gadget { size = 3; };
    expected = {
      size = 3;
      color = null;
    };
  };

  testObjectAcceptsAllProperties = {
    expr = check gadget {
      size = 3;
      color = "red";
    };
    expected = {
      size = 3;
      color = "red";
    };
  };

  testObjectOptionalAcceptsExplicitNull = {
    expr = check gadget {
      size = 3;
      color = null;
    };
    expected = {
      size = 3;
      color = null;
    };
  };

  testObjectRequiredMissingFails = {
    expr = rejects gadget { color = "red"; };
    expected = true;
  };

  testObjectUnknownKeyFails = {
    expr = rejects gadget {
      size = 3;
      bogus = 1;
    };
    expected = true;
  };

  testObjectWrongPropertyTypeFails = {
    expr = rejects gadget { size = "three"; };
    expected = true;
  };

  testObjectRejectsNonAttrs = {
    expr = rejects gadget "gadget";
    expected = true;
  };

  testObjectDefinitionsMerge = {
    expr = evalDefs gadget [
      { size = 3; }
      { color = "green"; }
    ];
    expected = {
      size = 3;
      color = "green";
    };
  };

  testObjectPreserveUnknownAcceptsUnknownKeys = {
    expr = check (gadget // { x-kubernetes-preserve-unknown-fields = true; }) {
      size = 3;
      extra.nested = [ 1 ];
    };
    expected = {
      size = 3;
      color = null;
      extra.nested = [ 1 ];
    };
  };

  testObjectPreserveUnknownStillChecksProperties = {
    expr = rejects (gadget // { x-kubernetes-preserve-unknown-fields = true; }) { size = "three"; };
    expected = true;
  };

  # Kubernetes has properties named like module keywords (e.g.
  # PodDNSConfig.options) and JSONSchemaProps has `$ref` and `x-kubernetes-*`.
  testPropertyNamesUsedVerbatim = {
    expr =
      check
        {
          type = "object";
          properties = {
            options = {
              type = "array";
              items.type = "string";
            };
            config.type = "string";
            imports.type = "integer";
            "$ref".type = "string";
            x-kubernetes-map-type.type = "string";
          };
        }
        {
          options = [ "ndots" ];
          config = "c";
          "$ref" = "#/definitions/x";
        };
    expected = {
      options = [ "ndots" ];
      config = "c";
      imports = null;
      "$ref" = "#/definitions/x";
      x-kubernetes-map-type = null;
    };
  };

  testPropertyDescriptions = {
    expr = lib.mapAttrs (_: opt: opt.description) (removeAttrs (subOptions gadget) [ "_module" ]);
    expected = {
      size = "How big the gadget is.";
      color = null;
    };
  };

  testNestedPropertyDescription = {
    expr =
      let
        sub = opt: opt.type.getSubOptions [ ];
      in
      (sub (sub (sub (subOptions deployment).template).spec).containers).name.description;
    expected = "Container name.";
  };

  # object with schema additionalProperties

  testMapAcceptsDottedAndDashedKeys = {
    expr = check stringMap {
      "app.conf" = "debug = true";
      "app.kubernetes.io/name" = "web";
      my-key = "v";
    };
    expected = {
      "app.conf" = "debug = true";
      "app.kubernetes.io/name" = "web";
      my-key = "v";
    };
  };

  testMapRejectsWrongValueType = {
    expr = rejects stringMap { replicas = 1; };
    expected = true;
  };

  testMapOfObjects = {
    expr = check {
      type = "object";
      additionalProperties = gadget;
    } { big.size = 10; };
    expected = {
      big = {
        size = 10;
        color = null;
      };
    };
  };

  testMapOfObjectsChecksValues = {
    expr = rejects {
      type = "object";
      additionalProperties = gadget;
    } { big.color = "red"; };
    expected = true;
  };

  # other objects / no type

  testOpenObjectAcceptsAnyAttrs = {
    expr = check { type = "object"; } {
      a = 1;
      b.c = "d";
    };
    expected = {
      a = 1;
      b.c = "d";
    };
  };

  testOpenObjectRejectsNonAttrs = {
    expr = rejects { type = "object"; } [ ];
    expected = true;
  };

  testAdditionalPropertiesTrueIsOpenObject = {
    expr = check {
      type = "object";
      additionalProperties = true;
    } { a.b = 1; };
    expected = {
      a.b = 1;
    };
  };

  testNoTypeAcceptsAnything = {
    expr = map (check { description = "Any JSON value."; }) [
      1
      "s"
      [ true ]
      { a = null; }
    ];
    expected = [
      1
      "s"
      [ true ]
      { a = null; }
    ];
  };

  # nesting

  testNestedObjects = {
    expr = check deployment {
      replicas = 2;
      selector.matchLabels.app = "web";
      template.spec.containers = [
        {
          name = "web";
          ports = [
            {
              containerPort = 80;
              targetPort = "http";
            }
          ];
        }
      ];
    };
    expected = {
      replicas = 2;
      selector.matchLabels.app = "web";
      template.spec.containers = [
        {
          name = "web";
          ports = [
            {
              containerPort = 80;
              targetPort = "http";
            }
          ];
        }
      ];
    };
  };

  testNestedRequiredMissingFails = {
    expr = rejects deployment { template.spec.containers = [ { ports = [ ]; } ]; };
    expected = true;
  };

  testNestedWrongTypeFails = {
    expr = rejects deployment {
      template.spec.containers = [
        {
          name = "web";
          ports = [ { containerPort = "80"; } ];
        }
      ];
    };
    expected = true;
  };

  testNestedUnknownKeyFails = {
    expr = rejects deployment { template.spec.containers = [ { image = "nginx"; } ]; };
    expected = true;
  };

  # laziness

  testBuildingTypeDoesNotForceProperties = {
    expr =
      (schemaType {
        type = "object";
        properties.bad = throw "property schema forced";
      }).name;
    expected = "submodule";
  };

  testRecursiveSchema = {
    expr = check tree {
      name = "a";
      child.name = "b";
    };
    expected = {
      name = "a";
      child = {
        name = "b";
        child = null;
      };
    };
  };
}
