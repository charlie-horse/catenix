# Unit tests for lib/normalize.nix: `$ref` resolution, `allOf` merging,
# recursion into nested schemas, the cycle guard, and laziness.
{
  lib,
  catenix,
  fixtures,
  helpers,
  ...
}:
let
  inherit (catenix.normalize) normalize;

  definitions = {
    Leaf = {
      type = "string";
      description = "A leaf.";
    };
    Alias."$ref" = "#/components/schemas/Leaf";
    Meta = {
      type = "object";
      description = "Metadata.";
      properties = {
        name.type = "string";
        labels = {
          type = "object";
          additionalProperties.type = "string";
        };
      };
    };
    Pair = {
      type = "object";
      properties = {
        left."$ref" = "Leaf";
        right."$ref" = "Leaf";
      };
    };
    Node = {
      type = "object";
      properties = {
        value."$ref" = "Leaf";
        next."$ref" = "#/components/schemas/Node";
      };
    };
    Tree = {
      type = "object";
      properties.children = {
        type = "array";
        items = {
          "$ref" = "#/definitions/Tree";
          description = "A subtree.";
        };
      };
    };
    Ping = {
      type = "object";
      properties.pong."$ref" = "Pong";
    };
    Pong = {
      type = "object";
      properties.ping."$ref" = "Ping";
    };
  };

  leaf = definitions.Leaf;

  # What a `$ref` already being resolved further up the path yields.
  stub = {
    type = "object";
    x-kubernetes-preserve-unknown-fields = true;
  };
in
{
  # $ref resolution

  testRefComponentsSchemas = {
    expr = normalize definitions { "$ref" = "#/components/schemas/Leaf"; };
    expected = leaf;
  };

  testRefDefinitions = {
    expr = normalize definitions { "$ref" = "#/definitions/Leaf"; };
    expected = leaf;
  };

  testRefBareName = {
    expr = normalize definitions { "$ref" = "Leaf"; };
    expected = leaf;
  };

  testRefChain = {
    expr = normalize definitions { "$ref" = "Alias"; };
    expected = leaf;
  };

  testRefTargetIsNormalized = {
    expr = normalize definitions { "$ref" = "Pair"; };
    expected = {
      type = "object";
      properties = {
        left = leaf;
        right = leaf;
      };
    };
  };

  testRefSiblingsMergedOverTarget = {
    expr = normalize definitions {
      "$ref" = "Leaf";
      description = "Overridden.";
      default = "x";
    };
    expected = {
      type = "string";
      description = "Overridden.";
      default = "x";
    };
  };

  testUnresolvableRefThrows = {
    expr = helpers.fails (normalize definitions { "$ref" = "#/components/schemas/Missing"; });
    expected = true;
  };

  testUnsupportedRefPrefixThrows = {
    expr = helpers.fails (normalize definitions { "$ref" = "#/components/parameters/Leaf"; });
    expected = true;
  };

  testUnresolvableNestedRefThrows = {
    expr = helpers.fails (normalize definitions { properties.bad."$ref" = "Missing"; });
    expected = true;
  };

  # allOf merging

  testAllOfMergesProperties = {
    expr = normalize definitions {
      allOf = [
        {
          type = "object";
          properties.a.type = "string";
        }
        {
          type = "object";
          properties.b.type = "integer";
        }
      ];
    };
    expected = {
      type = "object";
      properties = {
        a.type = "string";
        b.type = "integer";
      };
    };
  };

  testAllOfMergesPropertiesRecursively = {
    expr = normalize definitions {
      allOf = [
        {
          properties.meta = {
            type = "object";
            properties.name.type = "string";
            required = [ "name" ];
          };
        }
        {
          properties.meta = {
            type = "object";
            properties.uid.type = "string";
            required = [ "uid" ];
          };
        }
      ];
    };
    expected = {
      properties.meta = {
        type = "object";
        properties = {
          name.type = "string";
          uid.type = "string";
        };
        required = [
          "name"
          "uid"
        ];
      };
    };
  };

  testAllOfUnionsRequired = {
    expr =
      (normalize definitions {
        allOf = [
          {
            required = [
              "a"
              "b"
            ];
          }
          {
            required = [
              "b"
              "c"
            ];
          }
        ];
      }).required;
    expected = [
      "a"
      "b"
      "c"
    ];
  };

  testAllOfLaterDescriptionWins = {
    expr = normalize definitions {
      allOf = [
        { description = "first"; }
        { description = "second"; }
      ];
    };
    expected.description = "second";
  };

  testAllOfLaterMapTypeWins = {
    expr = normalize definitions {
      allOf = [
        { x-kubernetes-map-type = "granular"; }
        { x-kubernetes-map-type = "atomic"; }
      ];
    };
    expected.x-kubernetes-map-type = "atomic";
  };

  testAllOfSiblingsMergedLast = {
    expr = normalize definitions {
      allOf = [ { "$ref" = "Meta"; } ];
      default = { };
      description = "Sibling.";
    };
    expected = definitions.Meta // {
      default = { };
      description = "Sibling.";
    };
  };

  testAllOfEqualValuesAgree = {
    expr = normalize definitions {
      allOf = [
        {
          type = "object";
          nullable = true;
        }
        {
          type = "object";
          nullable = true;
        }
      ];
    };
    expected = {
      type = "object";
      nullable = true;
    };
  };

  testAllOfNested = {
    expr = normalize definitions {
      allOf = [
        { allOf = [ { properties.a."$ref" = "Leaf"; } ]; }
        { properties.b.type = "integer"; }
      ];
    };
    expected.properties = {
      a = leaf;
      b.type = "integer";
    };
  };

  testAllOfConflictThrows = {
    expr = helpers.fails (
      normalize definitions {
        allOf = [
          { type = "string"; }
          { type = "integer"; }
        ];
      }
    );
    expected = true;
  };

  testAllOfConflictingPropertyThrows = {
    expr = helpers.fails (
      normalize definitions {
        allOf = [
          { properties.a.type = "string"; }
          { properties.a.type = "integer"; }
        ];
      }
    );
    expected = true;
  };

  testAllOfConflictOnlyThrowsWhenForced = {
    expr =
      (normalize definitions {
        allOf = [
          {
            type = "string";
            description = "a";
          }
          { type = "integer"; }
        ];
      }).description;
    expected = "a";
  };

  # Recursion into nested schemas

  testRecursesIntoProperties = {
    expr = normalize definitions {
      type = "object";
      properties.leaf."$ref" = "Leaf";
    };
    expected = {
      type = "object";
      properties.leaf = leaf;
    };
  };

  testRecursesIntoItems = {
    expr = normalize definitions {
      type = "array";
      items."$ref" = "Leaf";
    };
    expected = {
      type = "array";
      items = leaf;
    };
  };

  testRecursesIntoObjectAdditionalProperties = {
    expr = normalize definitions {
      type = "object";
      additionalProperties."$ref" = "Leaf";
    };
    expected = {
      type = "object";
      additionalProperties = leaf;
    };
  };

  testBooleanAdditionalPropertiesUntouched = {
    expr = normalize definitions {
      type = "object";
      additionalProperties = false;
    };
    expected = {
      type = "object";
      additionalProperties = false;
    };
  };

  testRecursesIntoOneOf = {
    expr = normalize definitions {
      oneOf = [
        { "$ref" = "Leaf"; }
        { type = "integer"; }
      ];
    };
    expected.oneOf = [
      leaf
      { type = "integer"; }
    ];
  };

  testRecursesIntoAnyOf = {
    expr = normalize definitions {
      anyOf = [
        { "$ref" = "Leaf"; }
        { type = "integer"; }
      ];
    };
    expected.anyOf = [
      leaf
      { type = "integer"; }
    ];
  };

  testRecursesThroughNesting = {
    expr = normalize definitions {
      properties.meta.allOf = [ { "$ref" = "Meta"; } ];
      properties.matrix = {
        type = "array";
        items.additionalProperties.oneOf = [ { "$ref" = "Leaf"; } ];
      };
    };
    expected = {
      properties.meta = definitions.Meta;
      properties.matrix = {
        type = "array";
        items.additionalProperties.oneOf = [ leaf ];
      };
    };
  };

  testNonSchemaKeysUntouched = {
    expr = normalize definitions {
      type = "object";
      default."$ref" = "Missing";
      enum = [ { allOf = [ ]; } ];
      x-custom."$ref" = "Missing";
    };
    expected = {
      type = "object";
      default."$ref" = "Missing";
      enum = [ { allOf = [ ]; } ];
      x-custom."$ref" = "Missing";
    };
  };

  # Cycle guard

  testCycleGuardSelfReference = {
    expr = normalize definitions { "$ref" = "Node"; };
    expected = {
      type = "object";
      properties = {
        value = leaf;
        next = stub;
      };
    };
  };

  testCycleGuardMutualReference = {
    expr = normalize definitions { "$ref" = "Ping"; };
    expected = {
      type = "object";
      properties.pong = {
        type = "object";
        properties.ping = stub;
      };
    };
  };

  testCycleGuardKeepsSiblings = {
    expr = normalize definitions { "$ref" = "Tree"; };
    expected = {
      type = "object";
      properties.children = {
        type = "array";
        items = stub // {
          description = "A subtree.";
        };
      };
    };
  };

  # The guard only tracks refs, so a definition normalized directly (not via
  # `$ref`) unrolls one extra level before its self-reference is cut.
  testCycleGuardOnlyTracksRefs = {
    expr = normalize definitions definitions.Node;
    expected = {
      type = "object";
      properties = {
        value = leaf;
        next = {
          type = "object";
          properties = {
            value = leaf;
            next = stub;
          };
        };
      };
    };
  };

  # Laziness

  testNestedSchemasOnlyNormalizedWhenForced = {
    expr =
      (normalize definitions {
        properties = {
          ok.type = "string";
          bad."$ref" = "Missing";
        };
      }).properties.ok;
    expected.type = "string";
  };

  # Pass-through

  testNonObjectSchemasPassThrough = {
    expr = map (normalize definitions) [
      true
      false
      null
      "string"
    ];
    expected = [
      true
      false
      null
      "string"
    ];
  };

  testSchemaWithoutRefsUnchanged = {
    expr = normalize definitions definitions.Meta;
    expected = definitions.Meta;
  };

  # Realistic fixture: `$ref`, `allOf` with sibling `default`/`description`,
  # and the self-recursive `GadgetSpec.children`.

  testFixtureGadget =
    let
      schemas = (lib.importJSON "${fixtures}/openapi-minimal.json").components.schemas;
    in
    {
      expr = normalize schemas schemas."io.example.Gadget";
      expected = {
        type = "object";
        description = "A namespaced core-group test kind.";
        x-kubernetes-group-version-kind = [
          {
            group = "";
            version = "v1";
            kind = "Gadget";
          }
        ];
        properties = {
          apiVersion.type = "string";
          kind.type = "string";
          metadata = {
            type = "object";
            properties = {
              name.type = "string";
              namespace.type = "string";
              labels = {
                type = "object";
                additionalProperties.type = "string";
              };
            };
            default = { };
            description = "Standard object metadata.";
          };
          spec = {
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
                  "blue"
                ];
              };
              port = {
                type = "string";
                format = "int-or-string";
                x-kubernetes-int-or-string = true;
              };
              tags = {
                type = "array";
                items.type = "string";
              };
              children = {
                type = "array";
                items = stub;
              };
            };
            default = { };
          };
          enabled.type = "boolean";
        };
      };
    };

  testFixtureAllDefinitionsNormalize =
    let
      schemas = (lib.importJSON "${fixtures}/openapi-minimal.json").components.schemas;
    in
    {
      expr = helpers.fails (lib.mapAttrs (_: normalize schemas) schemas);
      expected = false;
    };
}
