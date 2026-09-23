{
  description = "Type-checked Kubernetes manifests, with lib.types built natively from the Kubernetes OpenAPI spec";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    kubernetes-src = {
      url = "git+https://github.com/kubernetes/kubernetes?ref=refs/tags/v1.37.0&shallow=1";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      kubernetes-src,
    }:
    let
      inherit (nixpkgs) lib;
      forAllSystems = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};
      catenix = import ./lib { inherit lib; };
    in
    {
      lib = catenix;

      nixosModules.default = import ./modules/default.nix {
        inherit catenix;
        kubernetesSrc = kubernetes-src;
      };

      tests = forAllSystems (
        system:
        import ./tests {
          inherit lib catenix;
          pkgs = pkgsFor system;
          kubernetesSrc = kubernetes-src;
          catenixModule = self.nixosModules.default;
        }
      );

      checks = forAllSystems (
        system:
        import ./tests/checks.nix {
          inherit
            lib
            nixpkgs
            kubernetes-src
            self
            system
            ;
          pkgs = pkgsFor system;
        }
      );

      apps = forAllSystems (system: {
        render = import ./apps/render.nix {
          inherit self;
          pkgs = pkgsFor system;
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nix-unit
              pkgs.yq-go
              pkgs.nixfmt
              pkgs.jq
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt);
    };
}
