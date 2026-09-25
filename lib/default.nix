# The flake's `lib` output: every catenix library unit, keyed by file name.
{ lib }:
let
  catenix = {
    utf8 = import ./utf8.nix { inherit lib; };
    pattern = import ./pattern.nix {
      inherit lib;
      inherit (catenix) utf8;
    };
    stringFormat = import ./stringFormat.nix {
      inherit lib;
      inherit (catenix) utf8;
    };
    normalize = import ./normalize.nix { inherit lib; };
    schemaType = import ./schemaType.nix { inherit lib catenix; };
    resourceModule = import ./resourceModule.nix { inherit lib catenix; };
    kubernetes = import ./kubernetes.nix { inherit lib; };
    crd = import ./crd.nix { inherit lib; };
    yaml2json = import ./yaml2json.nix;
    render = import ./render.nix { inherit lib; };
    mkKubernetesModule = import ./mkKubernetesModule.nix { inherit lib catenix; };
    importCrdModule = import ./importCrdModule.nix { inherit lib catenix; };
    manifestsToResources = import ./manifestsToResources.nix { inherit lib catenix; };
    helmTemplate = import ./helmTemplate.nix { inherit lib; };
    importChart = import ./importChart.nix { inherit lib catenix; };
  };
in
catenix
