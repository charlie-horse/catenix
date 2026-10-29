# A real CRD (the sample-controller `Foo` CRD shipped in the pinned Kubernetes
# source), through the full YAML -> CRD -> module -> YAML pipeline.
#
# `agnostic` cases are system-agnostic (tests/agnostic.nix): the YAML comes as
# `yaml2json`'s recorded output (checked by `contracts.sample-controller-crd`)
# through `crdModule`, the core of `importCrdModule`. `rendering` reads
# `build.yaml` back, so it runs per system (tests/per-system.nix).
{
  catenix,
  pkgs,
  helpers,
  recorded,
  catenixModule,
  ...
}:
let
  eval =
    modules:
    helpers.eval pkgs (
      [
        catenixModule
        (catenix.crdModule (recorded "sample-controller-crd"))
      ]
      ++ modules
    );

  example = {
    resources."samplecontroller.k8s.io".v1alpha1.Foo.example = {
      metadata.namespace = "default";
      spec = {
        deploymentName = "example-foo";
        replicas = 1;
      };
    };
  };
in
{
  agnostic = {
    # `rendering.testYaml` without the YAML.
    testManifests = {
      expr = (eval [ example ]).config.build.manifests;
      expected = [
        {
          apiVersion = "samplecontroller.k8s.io/v1alpha1";
          kind = "Foo";
          metadata = {
            name = "example";
            namespace = "default";
          };
          spec = {
            deploymentName = "example-foo";
            replicas = 1;
          };
        }
      ];
    };

    testWrongFieldTypeFails = {
      expr =
        helpers.fails
          (eval [
            { resources."samplecontroller.k8s.io".v1alpha1.Foo.bad.spec.replicas = "one"; }
          ]).config.build.manifests;
      expected = true;
    };

    testUnknownFieldFails = {
      expr =
        helpers.fails
          (eval [
            { resources."samplecontroller.k8s.io".v1alpha1.Foo.bad.spec.nope = 1; }
          ]).config.build.manifests;
      expected = true;
    };

    # The CRD declares `replicas` with `minimum: 1` and `maximum: 10`.
    testReplicasAboveMaximumFails = {
      expr =
        let
          fooWithReplicas =
            replicas:
            helpers.fails
              (eval [
                {
                  resources."samplecontroller.k8s.io".v1alpha1.Foo.example = {
                    metadata.namespace = "default";
                    spec = {
                      deploymentName = "example-foo";
                      inherit replicas;
                    };
                  };
                }
              ]).config.build.manifests;
        in
        {
          maximum = fooWithReplicas 10;
          aboveMaximum = fooWithReplicas 11;
        };
      expected = {
        maximum = false;
        aboveMaximum = true;
      };
    };
  };

  # Byte-level `build.yaml`, read back: per-system (tests/per-system.nix).
  rendering = {
    testYaml = {
      expr = builtins.readFile (eval [ example ]).config.build.yaml;
      expected = ''
        apiVersion: samplecontroller.k8s.io/v1alpha1
        kind: Foo
        metadata:
          name: example
          namespace: default
        spec:
          deploymentName: example-foo
          replicas: 1
      '';
    };
  };
}
