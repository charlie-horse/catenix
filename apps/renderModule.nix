# The `render` app's evaluation: the rendered YAML (`config.build.yaml`) of the
# module file at the absolute path `module`, composed with this flake's
# `nixosModules.default`. `pkgs` and `catenix` (the flake's `lib`) are
# `specialArgs`, so the module can use them in `imports`. `--impure` because
# the module lives outside the store:
#
#   nix build --impure --file apps/renderModule.nix --argstr module "$PWD/app.nix"
{
  module,
  system ? builtins.currentSystem,
}:
let
  flake = builtins.getFlake (toString ../.);
  inherit (flake.inputs) nixpkgs;
in
(nixpkgs.lib.evalModules {
  modules = [
    flake.nixosModules.default
    (/. + module)
  ];
  specialArgs = {
    pkgs = nixpkgs.legacyPackages.${system};
    catenix = flake.lib;
  };
}).config.build.yaml
