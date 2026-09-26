# The flake's system-agnostic `tests` output: every suite that needs no host
# system, as nix-unit `{ expr, expected }` cases. Run one with
# `nix-unit --flake .#tests.unit.normalize`.
#
# Nothing here builds at evaluation time. `pkgs` is a `throw`, so a suite that
# comes to depend on the host system fails loudly instead of silently running
# per system; it is still passed as the modules' `pkgs` argument, which stays
# unforced unless `build.yaml` is read. What import-from-derivation would
# return (parsed YAML, `helm template` renders) comes from the recordings in
# fixtures/recorded (`recorded "<name>"`, see recordings.nix), which the
# per-system `contracts` suites keep honest. The suites that only instantiate
# derivations (`drvPath`, attributes) use `referencePkgs`, one fixed system's
# nixpkgs: instantiating needs no builder, so they give the same result on
# every host.
{
  lib,
  catenix,
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
      referencePkgs
      kubernetesSrc
      certManagerChart
      catenixModule
      ;
    pkgs = throw "catenix tests: a system-agnostic suite forced pkgs";
    fixtures = ./fixtures;
    helpers = import ./helpers.nix { inherit lib; };
    recorded = name: lib.importJSON ./fixtures/recorded/${name}.json;
  };

  # An integration or e2e file's system-agnostic cases (its byte-level YAML
  # cases are per-system.nix's `rendering`).
  agnostic = file: (import file args).agnostic;
in
{
  unit = {
    utf8 = import ./unit/utf8.nix args;
    pattern = import ./unit/pattern.nix args;
    stringFormat = import ./unit/stringFormat.nix args;
    normalize = import ./unit/normalize.nix args;
    schemaType = import ./unit/schemaType.nix args;
    resourceModule = import ./unit/resourceModule.nix args;
    kubernetes = import ./unit/kubernetes.nix args;
    crd = import ./unit/crd.nix args;
    render = import ./unit/render.nix args;
    mkKubernetesModule = import ./unit/mkKubernetesModule.nix args;
    crdModule = import ./unit/crdModule.nix args;
    modules = import ./unit/modules.nix args;
    manifestsToResources = import ./unit/manifestsToResources.nix args;
    chartModule = import ./unit/chartModule.nix args;
    fetchChart = import ./unit/fetchChart.nix args;
  };
  integration = {
    basicResource = agnostic ./integration/basic-resource.nix;
    crdImport = agnostic ./integration/crd-import.nix;
    helmChart = agnostic ./integration/helm-chart.nix;
  };
  e2e = {
    realSpec = agnostic ./e2e/real-kubernetes-spec.nix;
    realCrd = agnostic ./e2e/real-crd.nix;
    helmCertManager = agnostic ./e2e/helm-cert-manager.nix;
  };
}
