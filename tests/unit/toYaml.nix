# `lib/render.nix`, `toYaml`: reads the built file back, so it's evaluated at
# `nix flake check` time rather than under nix-unit's sandbox.
{
  lib,
  catenix,
  pkgs,
  ...
}:
let
  render = manifests: builtins.readFile (catenix.render.toYaml pkgs manifests);

  # The rendered documents, parsed back by yq. yq reads YAML 1.2, so strings
  # only YAML 1.1 reads as booleans (`yes`, `on`) or base 60 numbers (`12:30`)
  # come back as strings either way; those are checked on the rendered text.
  roundTrip = manifests: catenix.yaml2json pkgs (catenix.render.toYaml pkgs manifests);

  # Strings Kubernetes' YAML parser (goyaml.v2: YAML 1.1 names, Go number
  # syntax) would read as something else if they were written unquoted, or
  # that are easy to write wrongly: each is checked as a key and a value.
  trickyStrings = [
    # numbers to goyaml.v2
    "08"
    "09"
    "0999"
    "0o17"
    "0o7"
    "0o_7"
    "-0o17"
    "0X1f"
    "+.5"
    "-.5"
    "0"
    "012"
    "-0"
    "+1"
    "1."
    ".5"
    "1e3"
    "1e-3"
    "0x1F"
    "0b101"
    "1_000"
    "1:20"
    ".inf"
    "-.inf"
    ".NaN"
    # booleans, nulls, timestamps, merge keys
    "true"
    "False"
    "null"
    "~"
    "2001-12-14"
    "<<"
    "="
    # indicators and whitespace
    ""
    " leading space"
    "trailing space "
    "a: b"
    "#x"
    "a #b"
    "- x"
    "*a"
    "&a"
    "!x"
    "%x"
    "@x"
    "`x"
    "{a}"
    "[a]"
    "'"
    "\""
    "a\tb"
    # plain scalars that a line fold would change
    (lib.concatStringsSep "   " (lib.genList (i: "word${toString i}") 40))
    # YAML line breaks JSON leaves raw: NEL, LS, PS
    (builtins.fromJSON ''"a\u0085b"'')
    (builtins.fromJSON ''"a b"'')
    (builtins.fromJSON ''"a b"'')
    # other text
    "héllo wörld"
    "日本語"
    "app.kubernetes.io/name"
    "nginx:1.27"
  ];

  multiLineStrings = [
    "x\n"
    "line one\nline two\n"
    "line one\nline two"
    "x\n\n"
    "\nx"
    " indented first line\nsecond\n"
    "trailing spaces   \nnext\n"
    "a\r\nb\r\n"
    "tab\tseparated\n\tindented\n"
    "a\n---\nb\n"
    "#!/bin/sh\necho \"hi\" # comment\n"
  ];

  configMap = {
    apiVersion = "v1";
    kind = "ConfigMap";
    metadata = {
      name = "settings";
      namespace = "default";
    };
    data."app.conf" = "debug = true";
  };

  deployment = {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata.name = "web";
    spec.replicas = 2;
  };
in
{
  testIsDerivation = {
    expr = lib.isDerivation (catenix.render.toYaml pkgs [ configMap ]);
    expected = true;
  };

  testEmpty = {
    expr = render [ ];
    expected = "";
  };

  testSingleDocument = {
    expr = render [ configMap ];
    expected = ''
      apiVersion: v1
      data:
        app.conf: debug = true
      kind: ConfigMap
      metadata:
        name: settings
        namespace: default
    '';
  };

  testDocumentsSeparatedInGivenOrder = {
    expr = render [
      configMap
      deployment
    ];
    expected = ''
      apiVersion: v1
      data:
        app.conf: debug = true
      kind: ConfigMap
      metadata:
        name: settings
        namespace: default
      ---
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: web
      spec:
        replicas: 2
    '';
  };

  testScalars = {
    expr = render [
      {
        count = 3;
        ratio = 2.5;
        enabled = true;
        text = "plain words";
        empty = { };
        none = [ ];
      }
    ];
    expected = ''
      count: 3
      empty: {}
      enabled: true
      none: []
      ratio: 2.5
      text: plain words
    '';
  };

  # Sequence dashes sit at their key's indentation, as in kubectl's output.
  testSequences = {
    expr = render [
      {
        spec.containers = [
          {
            name = "web";
            image = "nginx:1.27";
            ports = [ { containerPort = 80; } ];
          }
        ];
      }
    ];
    expected = ''
      spec:
        containers:
        - image: nginx:1.27
          name: web
          ports:
          - containerPort: 80
    '';
  };

  # Kubernetes parses YAML 1.1-style: unquoted `on`/`yes` would be booleans.
  testYaml11AmbiguousStringsQuoted = {
    expr = render [
      {
        data = {
          answer = "yes";
          enabled = "on";
          count = "3";
          "on" = "off";
        };
      }
    ];
    expected = ''
      data:
        answer: "yes"
        count: "3"
        enabled: "on"
        "on": "off"
    '';
  };

  # Every YAML 1.1 boolean spelling, as keys and values. yq (YAML 1.2) would
  # read them back as strings even unquoted, so this checks the text.
  testYaml11BooleanSpellingsQuoted = {
    expr = render [
      {
        data = lib.genAttrs [
          "y"
          "Y"
          "yes"
          "Yes"
          "YES"
          "n"
          "N"
          "no"
          "No"
          "NO"
          "on"
          "On"
          "ON"
          "off"
          "Off"
          "OFF"
        ] (s: s);
      }
    ];
    expected = ''
      data:
        "N": "N"
        "NO": "NO"
        "No": "No"
        "OFF": "OFF"
        "ON": "ON"
        "Off": "Off"
        "On": "On"
        "Y": "Y"
        "YES": "YES"
        "Yes": "Yes"
        "n": "n"
        "no": "no"
        "off": "off"
        "on": "on"
        "y": "y"
        "yes": "yes"
    '';
  };

  # YAML 1.1 base 60 (`12:30` is 750 to PyYAML). goyaml.v2 reads these as
  # strings, but its own encoder quotes them, as did this one before yq.
  testYaml11SexagesimalQuoted = {
    expr = render [
      {
        data = lib.genAttrs [
          "1:20"
          "12:30"
          "-1:20:30.5"
        ] (s: s);
      }
    ];
    expected = ''
      data:
        "-1:20:30.5": "-1:20:30.5"
        "12:30": "12:30"
        "1:20": "1:20"
    '';
  };

  # Go reads `08` as the float 8 and `0o17` as 15: quoted, they stay strings
  # (and ConfigMap keys keep their names).
  testGoNumberSyntaxQuoted = {
    expr = render [
      {
        data = lib.genAttrs [
          "08"
          "0o17"
          "+.5"
        ] (s: s);
      }
    ];
    expected = ''
      data:
        "+.5": "+.5"
        "08": "08"
        "0o17": "0o17"
    '';
  };

  testTrickyStringsStayStrings =
    let
      # yq, reading it back, takes even a quoted `<<` key for a merge key
      # (goyaml.v2 doesn't); `testMergeKeyQuoted` checks that one.
      keys = lib.genAttrs (lib.remove "<<" trickyStrings) (s: s);
    in
    {
      expr = roundTrip [
        {
          inherit keys;
          values = trickyStrings;
        }
      ];
      expected = [
        {
          inherit keys;
          values = trickyStrings;
        }
      ];
    };

  testMergeKeyQuoted = {
    expr = render [ { data."<<" = "<<"; } ];
    expected = ''
      data:
        "<<": "<<"
    '';
  };

  testMultiLineStringsStayTheSame = {
    expr = roundTrip [
      {
        keys = lib.genAttrs multiLineStrings (s: s);
        values = multiLineStrings;
      }
    ];
    expected = [
      {
        keys = lib.genAttrs multiLineStrings (s: s);
        values = multiLineStrings;
      }
    ];
  };

  testNonStringsStayTheSame = {
    expr = roundTrip [
      {
        ints = [
          0
          8
          (-1)
          9223372036854775807
        ];
        floats = [
          2.5
          1.0e-7
        ];
        bools = [
          true
          false
        ];
        nulls = [ null ];
        empty = {
          attrs = { };
          list = [ ];
        };
      }
    ];
    expected = [
      {
        ints = [
          0
          8
          (-1)
          9223372036854775807
        ];
        floats = [
          2.5
          1.0e-7
        ];
        bools = [
          true
          false
        ];
        nulls = [ null ];
        empty = {
          attrs = { };
          list = [ ];
        };
      }
    ];
  };

  # Multi-line strings (config files, scripts) are literal blocks, with the
  # chomping indicator their trailing newlines need.
  testMultiLineStringsAsLiteralBlocks = {
    expr = render [
      {
        data = {
          "app.conf" = "debug = true\nport = 8080\n";
          "run.sh" = "#!/bin/sh\nexec app";
          "notes.txt" = "keep\n\n";
        };
        args = [ "one\ntwo\n" ];
      }
    ];
    expected = ''
      args:
      - |
        one
        two
      data:
        app.conf: |
          debug = true
          port = 8080
        notes.txt: |+
          keep

        run.sh: |-
          #!/bin/sh
          exec app
    '';
  };
}
