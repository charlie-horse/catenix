# CustomResourceDefinition documents -> resource schema records.
#
# `loadCrds documents` takes parsed YAML documents, splices in the items of
# `List`/`CustomResourceDefinitionList` documents, skips empty (null) and
# non-CRD documents, validates each apiextensions.k8s.io/v1 CRD, and returns
# one record per served version (see "Resource schema record" in
# docs/DESIGN.md). Invalid CRDs, duplicate resources, and inputs without any
# CRD throw.
{ lib }:
let
  inherit (lib)
    assertMsg
    concatMap
    concatMapStringsSep
    concatStringsSep
    elem
    filter
    filterAttrs
    groupBy
    imap0
    isAttrs
    isBool
    isList
    isString
    length
    mapAttrsToList
    ;

  crdApiVersion = "apiextensions.k8s.io/v1";
  listKinds = [
    "List"
    "CustomResourceDefinitionList"
  ];
  scopes = [
    "Namespaced"
    "Cluster"
  ];

  nonEmptyString = value: isString value && value != "";

  flatten = concatMap (
    document:
    if document == null then
      [ ]
    else if isAttrs document && elem (document.kind or null) listKinds then
      flatten (if document.items or null == null then [ ] else document.items)
    else
      [ document ]
  );

  isCrd = document: isAttrs document && document.kind or null == "CustomResourceDefinition";

  nameOf = crd: crd.metadata.name or "<unnamed>";

  # The records of one CRD's served versions; throws if the CRD is invalid.
  crdRecords =
    crd:
    let
      check = cond: msg: assertMsg cond "catenix.crd: CustomResourceDefinition ${nameOf crd}: ${msg}";

      spec = crd.spec or null;
      preserveUnknownFields = spec.preserveUnknownFields or false;
      group = spec.group or null;
      kind = spec.names.kind or null;
      scope = spec.scope or null;
      versions = spec.versions or null;

      checkVersion =
        index: version:
        let
          at = "spec.versions[${toString index}]";
          schema = version.schema.openAPIV3Schema or null;
        in
        assert check (isAttrs version) "${at} must be an object";
        assert check (nonEmptyString (version.name or null)) "${at}.name must be a non-empty string";
        assert check (isBool (version.served or null)) "${at}.served must be a boolean";
        assert check (isAttrs schema) "${at}.schema.openAPIV3Schema must be an object";
        version;

      served = filter (version: version.served) (imap0 checkVersion versions);
    in
    assert check (crd.apiVersion or null == crdApiVersion)
      "apiVersion must be ${crdApiVersion}, got ${builtins.toJSON (crd.apiVersion or null)}";
    assert check (isAttrs spec) "spec must be an object";
    assert check (preserveUnknownFields != true) "spec.preserveUnknownFields must be false";
    assert check (nonEmptyString group) "spec.group must be a non-empty string";
    assert check (nonEmptyString kind) "spec.names.kind must be a non-empty string";
    assert check (elem scope scopes)
      "spec.scope must be Namespaced or Cluster, got ${builtins.toJSON scope}";
    assert check (isList versions && versions != [ ]) "spec.versions must be a non-empty list";
    assert check (served != [ ]) "no version is served";
    map (version: {
      inherit group kind;
      version = version.name;
      namespaced = scope == "Namespaced";
      schema = version.schema.openAPIV3Schema;
      definitions = { };
    }) served;
in
{
  loadCrds =
    documents:
    let
      crds = filter isCrd (flatten documents);

      entries = concatMap (
        crd:
        map (record: {
          crd = nameOf crd;
          inherit record;
        }) (crdRecords crd)
      ) crds;

      duplicates = filterAttrs (_: same: length same > 1) (
        groupBy (entry: "${entry.record.group}/${entry.record.version} ${entry.record.kind}") entries
      );

      describe = resource: same: "${resource} (from ${concatMapStringsSep ", " (entry: entry.crd) same})";
      duplicateList = concatStringsSep "; " (mapAttrsToList describe duplicates);
    in
    assert assertMsg (crds != [ ]) "catenix.crd: no CustomResourceDefinitions found";
    assert assertMsg (duplicates == { }) "catenix.crd: duplicate resources: ${duplicateList}";
    map (entry: entry.record) entries;
}
