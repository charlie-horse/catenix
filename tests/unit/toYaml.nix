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

  # remarshal (behind `pkgs.formats.yaml`) puts a sequence's dashes at its
  # key's indentation.
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
        answer: 'yes'
        count: '3'
        enabled: 'on'
        'on': 'off'
    '';
  };
}
