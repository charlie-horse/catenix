# `importCrdModule { pkgs, crdFile }`: the resource module for the
# CustomResourceDefinitions in a (multi-document) YAML file: `crdModule` over
# the parsed documents. Nix can't parse YAML, so reading the file is
# import-from-derivation (see yaml2json.nix), the only one here.
{ catenix, ... }:
{ pkgs, crdFile }:
catenix.crdModule (catenix.yaml2json pkgs crdFile)
