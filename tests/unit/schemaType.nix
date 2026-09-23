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

  int32 = {
    type = "integer";
    format = "int32";
  };

  # The sample-controller Foo CRD's `spec.replicas`.
  oneToTen = {
    type = "integer";
    minimum = 1;
    maximum = 10;
  };

  description = schema: (schemaType schema).description;
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

  # integer formats: Kubernetes decodes `format: int32` fields into Go int32s,
  # so larger values are rejected or silently wrapped (4294967298 -> 2).

  testInt32AcceptsLimits = {
    expr = map (check int32) [
      (-2147483648)
      2147483647
    ];
    expected = [
      (-2147483648)
      2147483647
    ];
  };

  testInt32RejectsAboveLimit = {
    expr = rejects int32 2147483648;
    expected = true;
  };

  testInt32RejectsBelowLimit = {
    expr = rejects int32 (-2147483649);
    expected = true;
  };

  testInt32RejectsValuesThatWrap = {
    expr = map (rejects int32) [
      3000000000
      4294967298
    ];
    expected = [
      true
      true
    ];
  };

  testInt32IsS32 = {
    expr = description int32;
    expected = lib.types.ints.s32.description;
  };

  testInt32DescriptionMentionsLimits = {
    expr = description int32;
    expected = "32 bit signed integer; between -2147483648 and 2147483647 (both inclusive)";
  };

  testInt32StillRejectsFloat = {
    expr = rejects int32 1.5;
    expected = true;
  };

  testInt64AcceptsBeyondInt32 = {
    expr =
      map
        (check {
          type = "integer";
          format = "int64";
        })
        [
          4294967298
          9223372036854775807
        ];
    expected = [
      4294967298
      9223372036854775807
    ];
  };

  testIntegerWithoutFormatAcceptsBeyondInt32 = {
    expr = check { type = "integer"; } 4294967298;
    expected = 4294967298;
  };

  testInt32OptionalPropertyIsNullOr = {
    expr =
      let
        schema = {
          type = "object";
          properties.replicas = int32;
        };
      in
      {
        absent = check schema { };
        rejected = rejects schema { replicas = 4294967298; };
        description = (subOptions schema).replicas.type.description;
      };
    expected = {
      absent.replicas = null;
      rejected = true;
      description = "null or 32 bit signed integer; between -2147483648 and 2147483647 (both inclusive)";
    };
  };

  # `enum` lists the allowed values itself; format and bounds don't widen it.
  testInt32EnumStillEnum = {
    expr =
      let
        schema = int32 // {
          enum = [
            1
            2
          ];
        };
      in
      {
        accepted = check schema 2;
        rejected = rejects schema 3;
      };
    expected = {
      accepted = 2;
      rejected = true;
    };
  };

  # A typeless oneOf maps each branch, so a branch's format applies to it.
  testInt32InsideOneOfBranch = {
    expr =
      let
        schema.oneOf = [
          int32
          { type = "string"; }
        ];
      in
      {
        accepted = map (check schema) [
          2147483647
          "x"
        ];
        rejected = rejects schema 2147483648;
      };
    expected = {
      accepted = [
        2147483647
        "x"
      ];
      rejected = true;
    };
  };

  # numeric bounds: minimum / maximum / exclusiveMinimum / exclusiveMaximum

  testBoundsAcceptInclusiveLimits = {
    expr = map (check oneToTen) [
      1
      5
      10
    ];
    expected = [
      1
      5
      10
    ];
  };

  testBoundsRejectBelowMinimum = {
    expr = rejects oneToTen 0;
    expected = true;
  };

  testBoundsRejectAboveMaximum = {
    expr = rejects oneToTen 11;
    expected = true;
  };

  testBoundsStillRejectWrongType = {
    expr = map (rejects oneToTen) [
      1.5
      "5"
    ];
    expected = [
      true
      true
    ];
  };

  testBoundsDescription = {
    expr = description oneToTen;
    expected = "integer between 1 and 10 (both inclusive)";
  };

  testBoundsOptionalPropertyIsNullOr = {
    expr =
      let
        schema = {
          type = "object";
          properties.replicas = oneToTen;
        };
      in
      {
        absent = check schema { };
        explicitNull = check schema { replicas = null; };
        accepted = check schema { replicas = 10; };
        rejected = rejects schema { replicas = 11; };
        description = (subOptions schema).replicas.type.description;
      };
    expected = {
      absent.replicas = null;
      explicitNull.replicas = null;
      accepted.replicas = 10;
      rejected = true;
      description = "null or integer between 1 and 10 (both inclusive)";
    };
  };

  testBoundsRequiredPropertyDescription = {
    expr =
      (subOptions {
        type = "object";
        required = [ "replicas" ];
        properties.replicas = oneToTen;
      }).replicas.type.description;
    expected = "integer between 1 and 10 (both inclusive)";
  };

  testMinimumOnly = {
    expr =
      let
        schema = {
          type = "integer";
          minimum = 0;
        };
      in
      {
        accepted = map (check schema) [
          0
          9223372036854775807
        ];
        rejected = rejects schema (-1);
        description = description schema;
      };
    expected = {
      accepted = [
        0
        9223372036854775807
      ];
      rejected = true;
      description = "integer at least 0";
    };
  };

  testMaximumOnly = {
    expr =
      let
        schema = {
          type = "integer";
          maximum = 10;
        };
      in
      {
        accepted = map (check schema) [
          (-9223372036854775807)
          10
        ];
        rejected = rejects schema 11;
        description = description schema;
      };
    expected = {
      accepted = [
        (-9223372036854775807)
        10
      ];
      rejected = true;
      description = "integer at most 10";
    };
  };

  # OpenAPI v3.0 (and so CRDs): a boolean flag makes minimum/maximum exclusive.
  testExclusiveBooleanForm = {
    expr =
      let
        schema = {
          type = "integer";
          minimum = 0;
          exclusiveMinimum = true;
          maximum = 10;
          exclusiveMaximum = true;
        };
      in
      {
        accepted = map (check schema) [
          1
          9
        ];
        rejected = map (rejects schema) [
          0
          10
        ];
        description = description schema;
      };
    expected = {
      accepted = [
        1
        9
      ];
      rejected = [
        true
        true
      ];
      description = "integer between 1 and 9 (both inclusive)";
    };
  };

  testExclusiveBooleanFalseIsInclusive = {
    expr =
      map
        (check {
          type = "integer";
          minimum = 0;
          exclusiveMinimum = false;
          maximum = 10;
          exclusiveMaximum = false;
        })
        [
          0
          10
        ];
    expected = [
      0
      10
    ];
  };

  # JSON Schema 2019-09 / OpenAPI 3.1: the exclusive bound is the number itself.
  testExclusiveNumericForm = {
    expr =
      let
        schema = {
          type = "integer";
          exclusiveMinimum = 0;
          exclusiveMaximum = 10;
        };
      in
      {
        accepted = map (check schema) [
          1
          9
        ];
        rejected = map (rejects schema) [
          0
          10
        ];
        description = description schema;
      };
    expected = {
      accepted = [
        1
        9
      ];
      rejected = [
        true
        true
      ];
      description = "integer between 1 and 9 (both inclusive)";
    };
  };

  # With both a numeric exclusive bound and minimum/maximum, both hold.
  testExclusiveNumericFormWithInclusiveBounds = {
    expr =
      let
        schema = {
          type = "integer";
          minimum = 5;
          exclusiveMinimum = 3;
          maximum = 8;
          exclusiveMaximum = 8;
        };
      in
      {
        accepted = map (check schema) [
          5
          7
        ];
        rejected = map (rejects schema) [
          4
          8
        ];
        description = description schema;
      };
    expected = {
      accepted = [
        5
        7
      ];
      rejected = [
        true
        true
      ];
      description = "integer between 5 and 7 (both inclusive)";
    };
  };

  # An integer bound need not be an integer.
  testIntegerFractionalBounds = {
    expr =
      let
        schema = {
          type = "integer";
          minimum = 0.5;
          maximum = 2.5;
        };
      in
      {
        accepted = map (check schema) [
          1
          2
        ];
        rejected = map (rejects schema) [
          0
          3
        ];
      };
    expected = {
      accepted = [
        1
        2
      ];
      rejected = [
        true
        true
      ];
    };
  };

  # int32 limits still hold next to looser (or one-sided) bounds.
  testInt32WithBounds = {
    expr =
      let
        schema = int32 // {
          minimum = 0;
          maximum = 1000000000000;
        };
      in
      {
        accepted = map (check schema) [
          0
          2147483647
        ];
        rejected = map (rejects schema) [
          (-1)
          2147483648
        ];
        description = description schema;
      };
    expected = {
      accepted = [
        0
        2147483647
      ];
      rejected = [
        true
        true
      ];
      description = "integer between 0 and 2147483647 (both inclusive)";
    };
  };

  testInt32WithMinimumOnly = {
    expr =
      let
        schema = int32 // {
          minimum = 1;
        };
      in
      {
        rejected = rejects schema 2147483648;
        description = description schema;
      };
    expected = {
      rejected = true;
      description = "integer between 1 and 2147483647 (both inclusive)";
    };
  };

  testNumberBoundsWithFloats = {
    expr =
      let
        schema = {
          type = "number";
          minimum = 0.5;
          maximum = 1.5;
        };
      in
      {
        accepted = map (check schema) [
          0.5
          1
          1.5
        ];
        rejected = map (rejects schema) [
          0.49
          1.51
          2
          "1"
        ];
        description = description schema;
      };
    expected = {
      accepted = [
        0.5
        1
        1.5
      ];
      rejected = [
        true
        true
        true
        true
      ];
      description = "integer or floating point number between 0.5 and 1.5 (both inclusive)";
    };
  };

  testNumberExclusiveBooleanForm = {
    expr =
      let
        schema = {
          type = "number";
          minimum = 0;
          exclusiveMinimum = true;
          maximum = 1;
        };
      in
      {
        accepted = map (check schema) [
          0.001
          1
        ];
        rejected = map (rejects schema) [
          0
          0.0
          1.001
        ];
        description = description schema;
      };
    expected = {
      accepted = [
        0.001
        1
      ];
      rejected = [
        true
        true
        true
      ];
      description = "integer or floating point number greater than 0 and at most 1";
    };
  };

  testNumberExclusiveNumericForm = {
    expr =
      let
        schema = {
          type = "number";
          exclusiveMinimum = 0;
          exclusiveMaximum = 1;
        };
      in
      {
        accepted = check schema 0.5;
        rejected = map (rejects schema) [
          0
          1.0
        ];
        description = description schema;
      };
    expected = {
      accepted = 0.5;
      rejected = [
        true
        true
      ];
      description = "integer or floating point number between 0 and 1 (both exclusive)";
    };
  };

  testNumberMaximumOnlyExclusive = {
    expr =
      let
        schema = {
          type = "number";
          maximum = 2.5;
          exclusiveMaximum = true;
        };
      in
      {
        accepted = check schema (-100);
        rejected = rejects schema 2.5;
        description = description schema;
      };
    expected = {
      accepted = -100;
      rejected = true;
      description = "integer or floating point number less than 2.5";
    };
  };

  testNumberBoundsOptionalPropertyIsNullOr = {
    expr =
      (subOptions {
        type = "object";
        properties.ratio = {
          type = "number";
          minimum = 0;
          maximum = 1;
        };
      }).ratio.type.description;
    expected = "null or integer or floating point number between 0 and 1 (both inclusive)";
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
