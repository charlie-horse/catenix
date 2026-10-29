# `apps.<system>.render`: `nix run .#render -- <path-to-module.nix>` prints the
# module's rendered YAML. The evaluation is renderModule.nix; the script only
# makes the path absolute, builds with the caller's `nix` and prints the file.
# Evaluation errors (type errors) exit non-zero.
{ pkgs, self }:
{
  type = "app";
  meta.description = "Print the rendered Kubernetes YAML of a catenix module file";
  program = pkgs.lib.getExe (
    pkgs.writeShellApplication {
      name = "catenix-render";
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        if [ $# -ne 1 ]; then
          echo "usage: nix run .#render -- <path-to-module.nix>" >&2
          exit 2
        fi
        yaml=$(nix build --impure --no-link --print-out-paths \
          --extra-experimental-features "nix-command flakes" \
          --file ${self}/apps/renderModule.nix \
          --argstr system ${pkgs.stdenv.hostPlatform.system} \
          --argstr module "$(realpath -- "$1")")
        cat "$yaml"
      '';
    }
  );
}
