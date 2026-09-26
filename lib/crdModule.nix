# `crdModule documents`: the resource module for the
# CustomResourceDefinitions among already-parsed documents
# (`crd.loadCrds` + `resourceModule.mkResourceModule`). Pure; `importCrdModule`
# is this over `yaml2json` of a YAML file.
{ catenix, ... }:
documents: catenix.resourceModule.mkResourceModule (catenix.crd.loadCrds documents)
