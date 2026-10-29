# Fixture-driven: a CRD from YAML (tests/fixtures/crd-widget.yaml,
# crd-portal.yaml), composed with the resource/build modules, declaring a
# custom resource end to end.
#
# `agnostic` cases are system-agnostic (tests/agnostic.nix): the YAML comes as
# `yaml2json`'s recorded output (checked by `contracts.crd-widget` and
# `contracts.crd-portal`) through `crdModule`, the core of `importCrdModule`.
# `rendering` reads `build.yaml` back, so it runs per system
# (tests/per-system.nix).
{
  lib,
  catenix,
  pkgs,
  helpers,
  recorded,
  ...
}:
let
  eval =
    modules:
    helpers.eval pkgs (
      [
        ../../modules/resources.nix
        ../../modules/build.nix
        (catenix.crdModule (recorded "crd-widget"))
      ]
      ++ modules
    );

  # A CRD with `pattern`, length, count and format constraints.
  evalPortal =
    spec:
    helpers.eval pkgs [
      ../../modules/resources.nix
      ../../modules/build.nix
      (catenix.crdModule (recorded "crd-portal"))
      {
        resources."example.com".v1.Portal.main = {
          metadata.namespace = "default";
          inherit spec;
        };
      }
    ];

  portalFails = spec: helpers.fails (evalPortal spec).config.build.manifests;

  # Within every constraint.
  constrained = evalPortal {
    listener = "web-1";
    hostnames = [
      "*.example.com"
      "example.org"
    ];
    timeout = "1m30s";
    headers.x-token = "c2VjcmV0";
    # `(?i)` has no POSIX translation: unchecked.
    caseless = "maybe";
  };

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
  agnostic = {
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

    # Constraints from the CRD schema: pattern, maxLength, maxItems,
    # maxProperties, format.

    testConstrainedCrdManifests = {
      expr = constrained.config.build.manifests;
      expected = [
        {
          apiVersion = "example.com/v1";
          kind = "Portal";
          metadata = {
            name = "main";
            namespace = "default";
          };
          spec = {
            listener = "web-1";
            hostnames = [
              "*.example.com"
              "example.org"
            ];
            timeout = "1m30s";
            headers.x-token = "c2VjcmV0";
            caseless = "maybe";
          };
        }
      ];
    };

    testConstraintViolationsFail = {
      expr = map portalFails [
        { listener = "Web"; }
        { listener = lib.concatStrings (lib.genList (_: "a") 64); }
        { listener = ""; }
        {
          listener = "web";
          hostnames = [ "-bad.example.com" ];
        }
        {
          listener = "web";
          hostnames = [
            "a.example"
            "b.example"
            "c.example"
          ];
        }
        {
          listener = "web";
          timeout = "90 seconds";
        }
        {
          listener = "web";
          headers.x-token = "not base64";
        }
        {
          listener = "web";
          headers = {
            a = "YQ==";
            b = "Yg==";
            c = "Yw==";
          };
        }
      ];
      expected = lib.genList (_: true) 8;
    };
  };

  # Byte-level `build.yaml`, read back: per-system (tests/per-system.nix).
  rendering = {
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

    testConstrainedCrdYaml = {
      expr = builtins.readFile constrained.config.build.yaml;
      expected = ''
        apiVersion: example.com/v1
        kind: Portal
        metadata:
          name: main
          namespace: default
        spec:
          caseless: maybe
          headers:
            x-token: c2VjcmV0
          hostnames:
          - '*.example.com'
          - example.org
          listener: web-1
          timeout: 1m30s
      '';
    };
  };
}
