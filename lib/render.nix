# Rendering: resource configs -> plain manifests -> a multi-document YAML file.
# Everything is pure Nix except `toYaml`, which builds the file.
{ lib }:
let
  # Recursively keeps the attributes for which `pred name value` holds,
  # descending into attrsets and lists.
  filterAttrsDeep =
    pred: value:
    if lib.isAttrs value then
      lib.mapAttrs (_: filterAttrsDeep pred) (lib.filterAttrs pred value)
    else if lib.isList value then
      map (filterAttrsDeep pred) value
    else
      value;

  stripNulls = filterAttrsDeep (_: value: value != null);

  # Also drops the `_module` attrs of submodule configs; the name is checked
  # first so `_module` itself is never forced.
  toPlain = filterAttrsDeep (name: value: name != "_module" && value != null);

  apiVersion =
    { group, version, ... }: if group == "" || group == "core" then version else "${group}/${version}";

  toManifest =
    {
      apiVersion,
      kind,
      name,
      body,
    }:
    toPlain (
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
    in
    forEach (toPlain resources) (
      group: versions:
      forEach versions (
        version: kinds:
        forEach kinds (
          kind: instances:
          lib.mapAttrsToList (
            name: body:
            toManifest {
              apiVersion = apiVersion { inherit group version; };
              inherit kind name body;
            }
          ) instances
        )
      )
    );

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
