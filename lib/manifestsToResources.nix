# `manifestsToResources { manifests, namespace ? null, noHooks ? false,
# skipTests ? false }`: a module defining `resources` from plain manifests
# (e.g. what `helm template` renders), so they are type-checked like any
# other resource and plain definitions override them field by field.
#
# - `v1` `List`s are flattened into their items.
# - Each manifest becomes `resources.<group|core>.<version>.<Kind>.<name>`,
#   without the fields `render` injects (`apiVersion`, `kind`,
#   `metadata.name`), the ones the API server sets (`status`,
#   `metadata.{uid, resourceVersion, generation, creationTimestamp,
#   deletionTimestamp, deletionGracePeriodSeconds, managedFields, selfLink}`),
#   which catenix's types reject, and `null`s (absent, to Kubernetes).
# - Every leaf (scalar, list or empty attrset) is defined at `mkDefault`
#   priority: attrsets merge with the user's definitions, whose leaves win;
#   lists are replaced whole; a user's `null` removes a field.
# - `metadata.namespace` is the manifest's own, else `namespace`, for
#   namespaced and unknown kinds; cluster-scoped kinds get none, even when the
#   manifest sets one (kubectl ignores it there, catenix rejects it). The scope
#   of a declared kind is read from `config.kinds`; an undeclared kind (only
#   accepted without `validation.strict`) is assumed namespaced.
# - Helm hooks (`helm.sh/hook` annotation) are kept as ordinary objects,
#   annotation included, unless `noHooks` (drops every hook) or `skipTests`
#   (drops hooks with a `test`/`test-success` event), like `helm template`'s
#   `--no-hooks` and `--skip-tests`.
#
# Throws on a manifest without `apiVersion`, `kind` or `metadata.name` (so
# `generateName` isn't supported), and on two manifests with the same
# group/version/kind/name, which one resource key can't hold (even in
# different namespaces).
{ lib, catenix }:
{
  manifests,
  namespace ? null,
  noHooks ? false,
  skipTests ? false,
}:
let
  inherit (catenix.render) stripNulls;

  flatten =
    manifest:
    if (manifest.apiVersion or null) == "v1" && (manifest.kind or null) == "List" then
      lib.concatMap flatten (manifest.items or [ ])
    else
      [ manifest ];

  hookEvents =
    manifest:
    let
      hook = manifest.metadata.annotations."helm.sh/hook" or null;
    in
    if hook == null then [ ] else map lib.trim (lib.splitString "," hook);

  isTestEvent = event: event == "test" || event == "test-success";

  kept =
    manifest:
    let
      events = hookEvents manifest;
    in
    !(noHooks && events != [ ]) && !(skipTests && lib.any isTestEvent events);

  serverSetMetadata = [
    "uid"
    "resourceVersion"
    "generation"
    "creationTimestamp"
    "deletionTimestamp"
    "deletionGracePeriodSeconds"
    "managedFields"
    "selfLink"
  ];

  describe = manifest: lib.generators.toPretty { } manifest;

  entry =
    manifest:
    let
      apiVersion =
        manifest.apiVersion
          or (throw "manifestsToResources: manifest without apiVersion:\n${describe manifest}");
      kind =
        manifest.kind or (throw "manifestsToResources: manifest without kind:\n${describe manifest}");
      name =
        manifest.metadata.name
          or (throw "manifestsToResources: ${kind} without metadata.name (generateName isn't supported):\n${describe manifest}");
      parts = lib.splitString "/" apiVersion;
      metadata = manifest.metadata or { };
    in
    {
      group = if lib.length parts == 1 then "core" else lib.head parts;
      version = lib.last parts;
      inherit kind name;
      namespace = metadata.namespace or namespace;
      metadata = removeAttrs metadata (
        [
          "name"
          "namespace"
        ]
        ++ serverSetMetadata
      );
      body = removeAttrs manifest [
        "apiVersion"
        "kind"
        "metadata"
        "status"
      ];
    };

  entries = map entry (builtins.filter kept (lib.concatMap flatten (map stripNulls manifests)));

  keyOf = e: "${e.group}/${e.version}/${e.kind}/${e.name}";

  duplicates = lib.attrNames (lib.filterAttrs (_: es: lib.length es > 1) (lib.groupBy keyOf entries));

  # Leaves at `mkDefault`; non-empty attrsets are recursed into, so they merge.
  defaults =
    value:
    if lib.isAttrs value && value != { } then lib.mapAttrs (_: defaults) value else lib.mkDefault value;
in
if duplicates != [ ] then
  throw "manifestsToResources: several manifests for ${lib.concatStringsSep ", " duplicates} (a resource key holds one object)"
else
  { config, ... }:
  let
    # Undeclared kinds (untyped, without `validation.strict`) count as namespaced.
    namespaced = e: lib.attrByPath [ e.group e.version e.kind "namespaced" ] true (config.kinds or { });

    # A plain `if`, not `mkIf`: a cluster-scoped kind may not declare
    # `namespace` at all, and even a disabled definition of an undeclared
    # option is an error.
    definition =
      e:
      lib.mapAttrs (_: defaults) e.body
      // {
        metadata =
          lib.mapAttrs (_: defaults) e.metadata
          // lib.optionalAttrs (e.namespace != null && namespaced e) {
            namespace = lib.mkDefault e.namespace;
          };
      };
  in
  {
    resources = lib.mkMerge (
      map (e: { ${e.group}.${e.version}.${e.kind}.${e.name} = definition e; }) entries
    );
  }
