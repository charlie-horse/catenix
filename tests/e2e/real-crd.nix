# A real CRD (the sample-controller `Foo` CRD shipped in the pinned Kubernetes
# source), through the full YAML -> CRD -> module -> YAML pipeline.
{
  catenix,
  pkgs,
  helpers,
  catenixModule,
  kubernetesSrc,
  ...
}:
let
  eval =
    modules:
    helpers.eval pkgs (
      [
        catenixModule
        (catenix.importCrdModule {
          inherit pkgs;
          crdFile = "${kubernetesSrc}/staging/src/k8s.io/sample-controller/artifacts/examples/crd.yaml";
        })
      ]
      ++ modules
    );
in
{
  testYaml = {
    expr =
      builtins.readFile
        (eval [
          {
            resources."samplecontroller.k8s.io".v1alpha1.Foo.example = {
              metadata.namespace = "default";
              spec = {
                deploymentName = "example-foo";
                replicas = 1;
              };
            };
          }
        ]).config.build.yaml;
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
}
