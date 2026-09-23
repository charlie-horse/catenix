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

  apiVersion =
    { group, version, ... }: if group == "" || group == "core" then version else "${group}/${version}";

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
    in
    forEach (stripNulls resources) (
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
