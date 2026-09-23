# The flake's `nixosModules.default`: resource options, rendering, and the core
# Kubernetes types built from the pinned `kubernetes-src` input.
{ catenix, kubernetesSrc }:
{
  imports = [
    ./resources.nix
    ./build.nix
    (catenix.mkKubernetesModule { inherit kubernetesSrc; })
  ];
}
