# Unit tests for lib/importCrdModule.nix: the resource module for the CRDs in
# a YAML file. Parsing YAML is import-from-derivation, so tests/flake-module.nix runs
# this suite at evaluation time rather than under nix-unit in a sandbox.
{
  lib,
  catenix,
  pkgs,
  fixtures,
  helpers,
  ...
}:
let
  inherit (catenix) importCrdModule;

  # Widget: namespaced, served v1 and unserved v1alpha1, plus a Namespace
  # document to skip.
  widgetFile = "${fixtures}/crd-widget.yaml";

  # A cluster-scoped kind in the same group, with the injected fields required.
  knobFile = pkgs.writeText "crd-knob.yaml" ''
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: knobs.example.com
    spec:
      group: example.com
      scope: Cluster
      names:
        kind: Knob
        plural: knobs
      versions:
        - name: v1
          served: true
          storage: true
          schema:
            openAPIV3Schema:
              type: object
              required: [apiVersion, kind]
              properties:
                apiVersion:
                  type: string
                kind:
                  type: string
                metadata:
                  type: object
                turns:
                  type: integer
  '';

  resourcesOf =
    crdFiles: config:
    (helpers.eval pkgs (
      map (crdFile: importCrdModule { inherit pkgs crdFile; }) crdFiles ++ [ config ]
    )).config.resources;

  # Config values as plain data: unset (null) optional fields dropped.
  plain =
    value:
    if lib.isAttrs value then
      lib.mapAttrs (_: plain) (lib.filterAttrs (_: v: v != null) value)
    else if lib.isList value then
      map plain value
    else
      value;

  rejects = crdFiles: config: helpers.fails (plain (resourcesOf crdFiles config));
in
{
  testDeclaresServedVersionsOnly = {
    expr = plain (resourcesOf [ widgetFile ] { });
    expected."example.com".v1.Widget = { };
  };

  testTypesInstances = {
    expr = plain (
      resourcesOf [ widgetFile ] {
        resources."example.com".v1.Widget.small = {
          metadata.namespace = "default";
          spec = {
            size = 1;
            extra.anything.goes = true;
          };
        };
      }
    );
    expected."example.com".v1.Widget.small = {
      metadata.namespace = "default";
      spec = {
        size = 1;
        extra.anything.goes = true;
      };
    };
  };

  testAcceptsPathCrdFile = {
    expr = plain (resourcesOf [ (fixtures + "/crd-widget.yaml") ] { });
    expected."example.com".v1.Widget = { };
  };

  testWrongFieldTypeFails = {
    expr = rejects [ widgetFile ] { resources."example.com".v1.Widget.bad.spec.size = "big"; };
    expected = true;
  };

  testMissingRequiredFieldFails = {
    expr = rejects [ widgetFile ] { resources."example.com".v1.Widget.bad.spec.label = "x"; };
    expected = true;
  };

  testUnknownFieldFails = {
    expr = rejects [ widgetFile ] { resources."example.com".v1.Widget.bad.spec.nope = 1; };
    expected = true;
  };

  testMetadataNameCannotBeSet = {
    expr = rejects [ widgetFile ] { resources."example.com".v1.Widget.bad.metadata.name = "bad"; };
    expected = true;
  };

  testUnservedVersionAbsent = {
    expr = rejects [ widgetFile ] { resources."example.com".v1alpha1.Widget.old = { }; };
    expected = true;
  };

  testClusterScopedRejectsNamespace = {
    expr = rejects [ knobFile ] { resources."example.com".v1.Knob.bad.metadata.namespace = "default"; };
    expected = true;
  };

  testRequiredInjectedFieldsNotNeeded = {
    expr = plain (resourcesOf [ knobFile ] { resources."example.com".v1.Knob.k.turns = 3; });
    expected."example.com".v1.Knob.k.turns = 3;
  };

  testModulesOfSeveralFilesMerge = {
    expr = plain (
      resourcesOf [ widgetFile knobFile ] {
        resources."example.com".v1 = {
          Widget.w.spec.size = 1;
          Knob.k.turns = 2;
        };
      }
    );
    expected."example.com".v1 = {
      Widget.w.spec.size = 1;
      Knob.k.turns = 2;
    };
  };

  testFileWithoutCrdsFails = {
    expr = rejects [ (pkgs.writeText "namespace.yaml" "apiVersion: v1\nkind: Namespace\n") ] { };
    expected = true;
  };

  testUnparsableFileFails = {
    expr = rejects [ (pkgs.writeText "broken.yaml" "a: [unclosed\n") ] { };
    expected = true;
  };
}
