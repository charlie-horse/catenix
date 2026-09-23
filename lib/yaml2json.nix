# `yaml2json pkgs yamlFile`: the documents of a (multi-document) YAML file as a
# list of Nix values, empty documents dropped. Nix has no YAML parser, so yq
# converts the file to one JSON array in a derivation that is read back with
# `builtins.fromJSON` (import-from-derivation).
#
# The builder never fails: yq's error message becomes the output instead, and
# is rethrown here, because a failed build can't be caught by `builtins.tryEval`
# while a `throw` can.
pkgs: yamlFile:
let
  inherit (pkgs) lib;

  # `./crd.yaml` and `/nix/store/<hash>-crd.yaml` both give `crd.yaml`.
  baseName = baseNameOf (toString yamlFile);
  fileName = if lib.isStorePath yamlFile then lib.substring 33 (-1) baseName else baseName;

  json = pkgs.runCommand (lib.strings.sanitizeDerivationName "${fileName}.json") {
    nativeBuildInputs = [ pkgs.yq-go ];
    inherit yamlFile;
  } ''yq -o=json -I=0 eval-all '[.]' "$yamlFile" > "$out" 2>&1 || true'';

  output = builtins.readFile json;
in
if lib.hasPrefix "[" output then
  builtins.filter (document: document != null) (builtins.fromJSON output)
else
  throw "yaml2json: cannot parse ${toString yamlFile}: ${lib.trim output}"
