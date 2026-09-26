# The suites that build derivations at evaluation time (import-from-derivation)
# with the host's `pkgs`: exposed as `legacyPackages.<system>.perSystemTests`
# and run during `nix flake check` as one named check each
# (tests/flake-module.nix). Everything else is system-agnostic (agnostic.nix).
#
# - `unit`: the IFD units themselves (`yaml2json`, `render.toYaml`,
#   `helmTemplate`) and one smoke case per adapter (`importCrdModule`,
#   `importChart`) for its wiring; the pure cores are agnostic.
# - `contracts.<name>`: each recording in fixtures/recorded equals the real
#   call it stands in for (recordings.nix).
# - `rendering`: the byte-level `build.yaml` cases of the integration and e2e
#   files (their `rendering` attribute).
{
  lib,
  catenix,
  pkgs,
  referencePkgs,
  kubernetesSrc,
  certManagerChart,
  catenixModule,
}:
let
  args = {
    inherit
      lib
      catenix
      pkgs
      referencePkgs
      kubernetesSrc
      certManagerChart
      catenixModule
      ;
    fixtures = ./fixtures;
    helpers = import ./helpers.nix { inherit lib; };
    recorded = name: lib.importJSON ./fixtures/recorded/${name}.json;
  };

  recordings = import ./recordings.nix {
    inherit
      catenix
      kubernetesSrc
      certManagerChart
      ;
    inherit (args) fixtures;
  };

  rendering = file: (import file args).rendering;
in
{
  unit = {
    yaml2json = import ./unit/yaml2json.nix args;
    toYaml = import ./unit/toYaml.nix args;
    helmTemplate = import ./unit/helmTemplate.nix args;
    importCrdModule = import ./unit/importCrdModule.nix args;
    importChart = import ./unit/importChart.nix args;
  };

  contracts = lib.mapAttrs (name: real: {
    testMatchesRecording = {
      expr = real pkgs;
      expected = args.recorded name;
    };
  }) recordings;

  rendering = {
    basicResource = rendering ./integration/basic-resource.nix;
    crdImport = rendering ./integration/crd-import.nix;
    helmChart = rendering ./integration/helm-chart.nix;
    realSpec = rendering ./e2e/real-kubernetes-spec.nix;
    realCrd = rendering ./e2e/real-crd.nix;
    helmCertManager = rendering ./e2e/helm-cert-manager.nix;
  };
}
