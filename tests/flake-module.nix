# Test wiring, as a flake-parts module.
#
# Pure suites go to nix-unit's flake-parts module (`perSystem.nix-unit.tests`),
# which exposes them as `tests.systems.<system>` and runs them all in the
# sandboxed `checks.<system>.nix-unit`. Suites that read a derivation's output
# back at evaluation time (YAML conversion/encoding) can't build inside that
# sandbox; they're exposed as `legacyPackages.<system>.evalTimeTests` for
# nix-unit and evaluated during `nix flake check` itself, one named check each,
# with `lib.debug.runTests` over the same `{ expr, expected }` cases.
{
  inputs,
  self,
  lib,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    let
      suites = import ./. {
        inherit lib pkgs;
        catenix = self.lib;
        kubernetesSrc = inputs.kubernetes-src;
        certManagerChart = inputs.cert-manager-chart;
        catenixModule = self.nixosModules.default;
      };

      helpers = import ./helpers.nix { inherit lib; };

      recordings = import ./recordings.nix {
        catenix = self.lib;
        fixtures = ./fixtures;
        kubernetesSrc = inputs.kubernetes-src;
        certManagerChart = inputs.cert-manager-chart;
      };

      evalTimeSuites = [
        "yaml2json"
        "toYaml"
        "importCrdModule"
        "helmTemplate"
        "importChart"
      ];

      evalTimeTests = {
        unit = lib.getAttrs evalTimeSuites suites.unit;
        inherit (suites) integration e2e;
        # Each recording in tests/fixtures/recorded equals the real call it
        # stands in for (tests/recordings.nix).
        contracts = lib.mapAttrs (name: real: {
          testMatchesRecording = {
            expr = real pkgs;
            expected = lib.importJSON ./fixtures/recorded/${name}.json;
          };
        }) recordings;
      };

      evalTime =
        name: suite:
        let
          failures = lib.debug.runTests suite;
        in
        if failures == [ ] then
          pkgs.runCommand name { } "touch $out"
        else
          throw "${name} failed:\n${lib.concatMapStringsSep "\n" describe failures}";

      # A failure as where the result first differs from the expectation
      # (recordings are too large to print whole).
      describe =
        failure:
        let
          difference = helpers.firstDifference failure.expected failure.result;
          pretty = lib.generators.toPretty { };
        in
        "${failure.name}: differs at ${
          if difference.path == "" then "the top" else difference.path
        }\n  expected: ${pretty difference.expected}\n  result:   ${pretty difference.actual}";
    in
    {
      nix-unit = {
        package = pkgs.nix-unit;
        inputs = {
          inherit (inputs)
            nixpkgs
            flake-parts
            nix-unit
            kubernetes-src
            cert-manager-chart
            ;
        };
        tests.unit = removeAttrs suites.unit evalTimeSuites;
      };

      legacyPackages = {
        inherit evalTimeTests;
        recordings = lib.mapAttrs (
          name: real:
          pkgs.runCommand "${name}.json" {
            nativeBuildInputs = [ pkgs.jq ];
            json = builtins.toJSON (real pkgs);
            passAsFile = [ "json" ];
          } ''jq . "$jsonPath" > "$out"''
        ) recordings;
      };

      checks = {
        unit-yaml2json = evalTime "unit-yaml2json" evalTimeTests.unit.yaml2json;
        unit-toYaml = evalTime "unit-toYaml" evalTimeTests.unit.toYaml;
        unit-importCrdModule = evalTime "unit-importCrdModule" evalTimeTests.unit.importCrdModule;
        unit-helmTemplate = evalTime "unit-helmTemplate" evalTimeTests.unit.helmTemplate;
        unit-importChart = evalTime "unit-importChart" evalTimeTests.unit.importChart;
        integration-basic-resource = evalTime "integration-basic-resource" evalTimeTests.integration.basicResource;
        integration-crd-import = evalTime "integration-crd-import" evalTimeTests.integration.crdImport;
        integration-helm-chart = evalTime "integration-helm-chart" evalTimeTests.integration.helmChart;
        e2e-real-spec = evalTime "e2e-real-spec" evalTimeTests.e2e.realSpec;
        e2e-real-crd = evalTime "e2e-real-crd" evalTimeTests.e2e.realCrd;
        e2e-helm-cert-manager = evalTime "e2e-helm-cert-manager" evalTimeTests.e2e.helmCertManager;
      }
      // lib.mapAttrs' (
        name: suite: lib.nameValuePair "contracts-${name}" (evalTime "contracts-${name}" suite)
      ) evalTimeTests.contracts;
    };
}
