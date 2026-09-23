# Rendering: resource configs -> plain manifests -> a multi-document YAML file.
# Everything is pure Nix except `toYaml`, which builds the file.
{ lib }:
let
  # Recursively drops `null` attribute values, descending into attrsets and
  # lists. Submodule configs carry no `_module` (`evalModules` removes it), so
  # every other attribute, `_module` included, is the user's data.
  stripNulls =
    value:
    if lib.isAttrs value then
      lib.mapAttrs (_: stripNulls) (lib.filterAttrs (_: v: v != null) value)
    else if lib.isList value then
      map stripNulls value
    else
      value;

  isCoreGroup = group: group == "" || group == "core";

  apiVersion = { group, version, ... }: if isCoreGroup group then version else "${group}/${version}";

  toManifest =
    {
      apiVersion,
      kind,
      name,
      body,
    }:
    stripNulls (
      body
      // {
        inherit apiVersion kind;
        metadata = lib.optionalAttrs ((body.metadata or null) != null) body.metadata // {
          inherit name;
        };
      }
    );

  manifestsFromResources =
    resources:
    let
      # `f name value` for every attribute, concatenated in attribute order.
      forEach = attrs: f: lib.concatLists (lib.mapAttrsToList f attrs);

      # Every instance, sorted by group, version, kind and name.
      instances = forEach (stripNulls resources) (
        group: versions:
        forEach versions (
          version: kinds:
          forEach kinds (
            kind:
            lib.mapAttrsToList (
              name: body: {
                inherit
                  group
                  version
                  kind
                  name
                  body
                  ;
              }
            )
          )
        )
      );

      # `kubectl apply -f` creates objects in file order, so what others need
      # goes first: namespaces (for namespaced objects), then CRDs (for custom
      # resources).
      rank =
        { group, kind, ... }:
        if isCoreGroup group && kind == "Namespace" then
          0
        else if group == "apiextensions.k8s.io" && kind == "CustomResourceDefinition" then
          1
        else
          2;
    in
    # `sortOn` is stable: within a rank, instances keep their order.
    map (
      instance:
      toManifest {
        apiVersion = apiVersion instance;
        inherit (instance) kind name body;
      }
    ) (lib.sortOn rank instances);

  toYaml =
    pkgs: manifests:
    let
      # YAML 1.1 quotes strings like `on`/`yes` that Kubernetes' parser would
      # otherwise read as booleans.
      inherit (pkgs.formats.yaml { }) generate;
      documents = lib.imap0 (i: generate "manifest-${toString i}.yaml") manifests;
    in
    # remarshal starts each file with a "%YAML 1.1" directive and a "---"
    # marker; drop those and put one "---" line between documents.
    pkgs.runCommand "manifests.yaml" { inherit documents; } ''
      sep=
      for doc in $documents; do
        printf '%s' "$sep"
        sed '1,2{/^%YAML /d; /^---$/d}' "$doc"
        sep=$'---\n'
      done > "$out"
    '';
in
{
  inherit
    stripNulls
    apiVersion
    toManifest
    manifestsFromResources
    toYaml
    ;
}
