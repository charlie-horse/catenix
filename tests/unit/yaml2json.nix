# Unit tests for lib/yaml2json.nix. Every case builds a derivation and reads it
# back (import-from-derivation), so tests/checks.nix runs this suite at
# evaluation time rather than under nix-unit in a sandbox.
{
  catenix,
  pkgs,
  fixtures,
  helpers,
  ...
}:
let
  yaml2json = catenix.yaml2json pkgs;
  fromText = name: text: yaml2json (pkgs.writeText name text);

  widget = yaml2json "${fixtures}/crd-widget.yaml";
  crd = builtins.elemAt widget 0;

  scalars = builtins.head (
    fromText "scalars.yaml" ''
      int: 42
      negative: -7
      zero: 0
      float: 1.5
      wholeFloat: 1.0
      bool: true
      falsy: false
      quotedFloat: "1.0"
      quotedInt: '42'
      quotedBool: "true"
      nothing: null
      tilde: ~
      str: hello
      date: 2024-01-01
      multiline: |
        line1
        line2
      list: [1, "two", true, 1.5, null]
      emptyList: []
      emptyMap: {}
      nested:
        a:
          b:
            - c: 1
              d: [x, y]
            - e:
                f: false
    ''
  );
in
{
  testFixtureHasTwoDocuments = {
    expr = builtins.length widget;
    expected = 2;
  };

  testFixtureCrdHeader = {
    expr = {
      inherit (crd) apiVersion kind metadata;
      inherit (crd.spec) group scope names;
    };
    expected = {
      apiVersion = "apiextensions.k8s.io/v1";
      kind = "CustomResourceDefinition";
      metadata.name = "widgets.example.com";
      group = "example.com";
      scope = "Namespaced";
      names = {
        kind = "Widget";
        plural = "widgets";
        singular = "widget";
      };
    };
  };

  testFixtureCrdVersions = {
    expr = map (version: {
      inherit (version) name served storage;
    }) crd.spec.versions;
    expected = [
      {
        name = "v1";
        served = true;
        storage = true;
      }
      {
        name = "v1alpha1";
        served = false;
        storage = false;
      }
    ];
  };

  testFixtureCrdSchema = {
    expr = (builtins.head crd.spec.versions).schema.openAPIV3Schema.properties.spec;
    expected = {
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

  testFixtureSecondDocument = {
    expr = builtins.elemAt widget 1;
    expected = {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = "not-a-crd";
    };
  };

  testAcceptsPathValue = {
    expr = yaml2json (fixtures + "/crd-widget.yaml");
    expected = widget;
  };

  testSingleDocument = {
    expr = fromText "single.yaml" ''
      name: solo
      replicas: 3
    '';
    expected = [
      {
        name = "solo";
        replicas = 3;
      }
    ];
  };

  testEmptyDocumentsDropped = {
    expr = fromText "gaps.yaml" ''
      ---
      a: 1
      ---
      ---
      b: 2
      ---
    '';
    expected = [
      { a = 1; }
      { b = 2; }
    ];
  };

  testCommentOnlyDocumentsDropped = {
    expr = fromText "comments.yaml" ''
      # a leading comment-only document
      ---
      a: 1
      ---
      # a trailing comment-only document
    '';
    expected = [ { a = 1; } ];
  };

  testEmptyFile = {
    expr = fromText "empty.yaml" "";
    expected = [ ];
  };

  testNonMappingDocuments = {
    expr = fromText "non-mapping.yaml" ''
      - a
      - b
      ---
      hello
      ---
      7
    '';
    expected = [
      [
        "a"
        "b"
      ]
      "hello"
      7
    ];
  };

  testScalarValues = {
    expr = scalars;
    expected = {
      int = 42;
      negative = -7;
      zero = 0;
      float = 1.5;
      wholeFloat = 1.0;
      bool = true;
      falsy = false;
      quotedFloat = "1.0";
      quotedInt = "42";
      quotedBool = "true";
      nothing = null;
      tilde = null;
      str = "hello";
      date = "2024-01-01";
      multiline = "line1\nline2\n";
      list = [
        1
        "two"
        true
        1.5
        null
      ];
      emptyList = [ ];
      emptyMap = { };
      nested.a.b = [
        {
          c = 1;
          d = [
            "x"
            "y"
          ];
        }
        { e.f = false; }
      ];
    };
  };

  # `1 == 1.0` in Nix, so value equality alone can't tell ints from floats.
  testScalarTypes = {
    expr = builtins.mapAttrs (_: builtins.typeOf) scalars;
    expected = {
      int = "int";
      negative = "int";
      zero = "int";
      float = "float";
      wholeFloat = "float";
      bool = "bool";
      falsy = "bool";
      quotedFloat = "string";
      quotedInt = "string";
      quotedBool = "string";
      nothing = "null";
      tilde = "null";
      str = "string";
      date = "string";
      multiline = "string";
      list = "list";
      emptyList = "list";
      emptyMap = "set";
      nested = "set";
    };
  };

  testListElementTypes = {
    expr = map builtins.typeOf scalars.list;
    expected = [
      "int"
      "string"
      "bool"
      "float"
      "null"
    ];
  };

  testInvalidYamlFails = {
    expr = helpers.fails (fromText "invalid.yaml" "a: [unclosed\n");
    expected = true;
  };

  testBadIndentationFails = {
    expr = helpers.fails (
      fromText "bad-indentation.yaml" ''
        a:
          b: 1
         c: 2
      ''
    );
    expected = true;
  };
}
