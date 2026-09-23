# The flake's `tests` output: every suite as nix-unit `{ expr, expected }` cases.
{
  lib,
  catenix,
  pkgs,
  kubernetesSrc,
  catenixModule,
}:
let
  args = {
    inherit
      lib
      catenix
      pkgs
      kubernetesSrc
      catenixModule
      ;
    fixtures = ./fixtures;
    helpers = import ./helpers.nix { inherit lib; };
  };
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
    yaml2json = import ./unit/yaml2json.nix args;
    render = import ./unit/render.nix args;
    toYaml = import ./unit/toYaml.nix args;
    mkKubernetesModule = import ./unit/mkKubernetesModule.nix args;
    importCrdModule = import ./unit/importCrdModule.nix args;
    modules = import ./unit/modules.nix args;
  };
  integration = {
    basicResource = import ./integration/basic-resource.nix args;
    crdImport = import ./integration/crd-import.nix args;
  };
  e2e = {
    realSpec = import ./e2e/real-kubernetes-spec.nix args;
    realCrd = import ./e2e/real-crd.nix args;
  };
}
