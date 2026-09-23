# `importCrdModule { pkgs, crdFile }`: the resource module for the
# CustomResourceDefinitions in a (multi-document) YAML file. Nix can't parse
# YAML, so reading the file is import-from-derivation (see yaml2json.nix).
{ catenix, ... }:
{ pkgs, crdFile }:
catenix.resourceModule.mkResourceModule (catenix.crd.loadCrds (catenix.yaml2json pkgs crdFile))
