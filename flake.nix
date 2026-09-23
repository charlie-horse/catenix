{
  description = "Type-checked Kubernetes manifests, with lib.types built natively from the Kubernetes OpenAPI spec";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nix-unit = {
      url = "github:nix-community/nix-unit";
      inputs.nixpkgs.follows = "nixpkgs";
      # Only used by nix-unit's own dev tooling; pointed at this flake so they
      # are never fetched.
      inputs.treefmt-nix.follows = "";
      inputs.nix-github-actions.follows = "";
    };
    kubernetes-src = {
      url = "git+https://github.com/kubernetes/kubernetes?ref=refs/tags/v1.37.0&shallow=1";
      flake = false;
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } (
      { self, lib, ... }:
      {
        systems = [
          "x86_64-linux"
          "aarch64-linux"
          "x86_64-darwin"
          "aarch64-darwin"
        ];

        imports = [
          inputs.nix-unit.modules.flake.default
          ./tests/flake-module.nix
        ];

        flake = {
          lib = import ./lib { inherit lib; };

          nixosModules.default = import ./modules/default.nix {
            catenix = self.lib;
            kubernetesSrc = inputs.kubernetes-src;
          };
        };

        perSystem =
          { pkgs, ... }:
          {
            apps.render = import ./apps/render.nix { inherit pkgs self; };

            devShells.default = pkgs.mkShell {
              packages = [
                pkgs.nix-unit
                pkgs.yq-go
                pkgs.nixfmt
                pkgs.jq
              ];
            };

            formatter = pkgs.nixfmt;
          };
      }
    );
}
