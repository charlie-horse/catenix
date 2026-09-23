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

  # NEL, LS and PS: JSON allows them raw in strings, but YAML reads them as
  # line breaks, so they're turned into JSON escapes before yq reads JSON as
  # YAML. (The rest of JSON's structure is ASCII, so only strings change.)
  escapeYamlLineBreaks =
    let
      escapes = [
        "\\u0085"
        "\\u2028"
        "\\u2029"
      ];
    in
    builtins.replaceStrings (map (e: builtins.fromJSON ''"${e}"'') escapes) escapes;

  # Strings YAML 1.1 reads as something else but yq's encoder, going by YAML
  # 1.2, would leave plain: booleans (`yes`, `on`, ...; in any case, as yq's
  # `-P` matches them) and base 60 numbers (`12:30`; go-yaml's regex). These
  # are the extra strings go-yaml's own encoder quotes.
  yaml11Scalar = "^(?i:y|yes|n|no|on|off)$|^[-+]?[0-9][0-9_]*(?::[0-5]?[0-9])+(?:\\.[0-9_]*)?$";

  # yq reads the JSON as YAML (`-p json` would turn numbers into floats and
  # lose big ints) and writes it back as block YAML once every node's style
  # is reset (JSON's are flow maps and double-quoted strings), except that
  # `yaml11Scalar` strings keep their double quotes. yq's encoder quotes every
  # other string that would read back as something else (`08`, `0o17`,
  # `true`, `<<`, ...) and writes multi-line strings as literal blocks. `-c`
  # puts sequence dashes at their key's indentation; `split_doc` makes each
  # manifest its own `---`-separated document. Keys keep Nix's (sorted)
  # attribute order.
  toYaml =
    pkgs: manifests:
    pkgs.runCommand "manifests.yaml"
      {
        nativeBuildInputs = [ pkgs.yq-go ];
        json = escapeYamlLineBreaks (builtins.toJSON manifests);
        passAsFile = [ "json" ];
        inherit yaml11Scalar;
      }
      ''yq -p yaml -o yaml -c '(... | select(tag != "!!str" or (test(strenv(yaml11Scalar)) | not))) style = "" | .[] | split_doc' "$jsonPath" > "$out"'';
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
