# The flake's `checks.<system>`: one named check per test suite.
#
# Pure suites run under nix-unit inside a derivation, per nix-unit's flake
# example. Suites that read a derivation's output back at evaluation time
# (YAML conversion/encoding) can't build inside that sandbox, so they're
# evaluated during `nix flake check` itself with `lib.debug.runTests` over the
# same `{ expr, expected }` cases.
{
  lib,
  pkgs,
  nixpkgs,
  kubernetes-src,
  self,
}:
let
  tests = import ./. {
    inherit lib pkgs;
    catenix = self.lib;
    kubernetesSrc = kubernetes-src;
    catenixModule = self.nixosModules.default;
  };

  nixUnit =
    name: path:
    pkgs.runCommand name { nativeBuildInputs = [ pkgs.nix-unit ]; } ''
      export HOME="$(realpath .)"
      nix-unit --eval-store "$HOME" \
        --extra-experimental-features "nix-command flakes" \
        --override-input nixpkgs ${nixpkgs} \
        --override-input kubernetes-src ${kubernetes-src} \
        --flake ${self}#tests.${path}
      touch $out
    '';

  evalTime =
    name: suite:
    let
      failures = lib.debug.runTests suite;
    in
    if failures == [ ] then
      pkgs.runCommand name { } "touch $out"
    else
      throw "${name} failed:\n${lib.generators.toPretty { } failures}";
in
{
  unit-normalize = nixUnit "unit-normalize" "unit.normalize";
  unit-schemaType = nixUnit "unit-schemaType" "unit.schemaType";
  unit-resourceModule = nixUnit "unit-resourceModule" "unit.resourceModule";
  unit-kubernetes = nixUnit "unit-kubernetes" "unit.kubernetes";
  unit-crd = nixUnit "unit-crd" "unit.crd";
  unit-render = nixUnit "unit-render" "unit.render";
  unit-mkKubernetesModule = nixUnit "unit-mkKubernetesModule" "unit.mkKubernetesModule";
  unit-modules = nixUnit "unit-modules" "unit.modules";
  unit-yaml2json = evalTime "unit-yaml2json" tests.unit.yaml2json;
  unit-toYaml = evalTime "unit-toYaml" tests.unit.toYaml;
  unit-importCrdModule = evalTime "unit-importCrdModule" tests.unit.importCrdModule;
  integration-basic-resource = evalTime "integration-basic-resource" tests.integration.basicResource;
  integration-crd-import = evalTime "integration-crd-import" tests.integration.crdImport;
  e2e-real-spec = evalTime "e2e-real-spec" tests.e2e.realSpec;
  e2e-real-crd = evalTime "e2e-real-crd" tests.e2e.realCrd;
}
