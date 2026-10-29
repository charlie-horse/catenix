# Schema normalization: turns a raw OpenAPI/CRD JSON Schema into one that
# `schemaType` can map directly, by resolving `$ref`s against a definitions
# table, folding `allOf` branches into a single schema, and doing the same for
# every nested schema (`properties`, `items`, object `additionalProperties`,
# `oneOf`, `anyOf`). A `$ref` already being resolved further up the path is
# replaced by a stub that accepts any object, so recursive schemas terminate.
# Lazy: nested schemas are only normalized when forced.
{ lib }:
let
  inherit (builtins)
    elemAt
    intersectAttrs
    isAttrs
    match
    ;
  inherit (lib)
    all
    concatLists
    elem
    head
    last
    length
    mapAttrs
    unique
    zipAttrsWith
    ;

  # What a `$ref` already being resolved further up the path resolves to.
  recursionStub = {
    type = "object";
    x-kubernetes-preserve-unknown-fields = true;
  };

  # `#/components/schemas/<n>`, `#/definitions/<n>`, or a bare `<n>` → `<n>`.
  refName =
    ref:
    let
      m = match "#/(components/schemas|definitions)/(.+)" ref;
    in
    if m == null then ref else elemAt m 1;

  # Keys where, across `allOf` branches, the last one wins instead of having to agree.
  lastWins = [
    "description"
    "x-kubernetes-map-type"
  ];

  # Merges already-normalized schemas (the branches of one `allOf`, in order).
  mergeSchemas =
    schemas:
    if length schemas == 1 then
      head schemas
    else if all isAttrs schemas then
      zipAttrsWith mergeKey schemas
    else
      agree "schema" schemas;

  mergeKey =
    key: values:
    if length values == 1 then
      head values
    else if key == "properties" then
      zipAttrsWith (_: mergeSchemas) values
    else if key == "required" then
      unique (concatLists values)
    else if elem key lastWins then
      last values
    else
      agree key values;

  agree =
    key: values:
    if all (v: v == head values) values then
      head values
    else
      throw "catenix.normalize: allOf branches disagree on \"${key}\"";
in
{
  normalize =
    definitions:
    let
      # `resolving`: the names of the refs being resolved on the current path.
      go =
        resolving: schema:
        if !isAttrs schema then
          schema
        else if schema ? "$ref" then
          resolveRef resolving schema
        else if schema ? allOf then
          # Sibling keys act as a final branch, so their `description` wins.
          mergeSchemas (map (go resolving) (schema.allOf ++ [ (removeAttrs schema [ "allOf" ]) ]))
        else
          schema // mapAttrs (key: walk: walk schema.${key}) (intersectAttrs schema (subschemas resolving));

      # Sibling keys next to `$ref` are merged over the resolved target.
      resolveRef =
        resolving: schema:
        let
          ref = schema."$ref";
          name = refName ref;
          siblings = removeAttrs schema [ "$ref" ];
        in
        if resolving ? ${name} then
          go resolving (recursionStub // siblings)
        else if definitions ? ${name} then
          go (resolving // { ${name} = true; }) (definitions.${name} // siblings)
        else
          throw "catenix.normalize: unresolvable $ref \"${ref}\"";

      # How to normalize the value of each key that holds nested schemas.
      subschemas = resolving: {
        properties = mapAttrs (_: go resolving);
        items = go resolving;
        additionalProperties = go resolving; # booleans pass through `go`
        oneOf = map (go resolving);
        anyOf = map (go resolving);
      };
    in
    go { };
}
