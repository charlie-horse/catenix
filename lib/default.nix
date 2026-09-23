# The flake's `lib` output: every catenix library unit, keyed by file name.
{ lib }:
let
  catenix = {
    normalize = import ./normalize.nix { inherit lib; };
    schemaType = import ./schemaType.nix { inherit lib; };
    resourceModule = import ./resourceModule.nix { inherit lib catenix; };
    kubernetes = import ./kubernetes.nix { inherit lib; };
    crd = import ./crd.nix { inherit lib; };
    yaml2json = import ./yaml2json.nix;
    render = import ./render.nix { inherit lib; };
    mkKubernetesModule = import ./mkKubernetesModule.nix { inherit lib catenix; };
    importCrdModule = import ./importCrdModule.nix { inherit lib catenix; };
  };
in
catenix
