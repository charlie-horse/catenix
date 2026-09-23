# Maps one normalized JSON schema (no `$ref`/`allOf`) to a `lib.types` value.
#
# Object properties become submodule options built lazily with `mapAttrs`, so
# nested types exist only once something (a definition, the docs) asks for them.
{ lib }:
let
  inherit (lib) types;

  isObject = schema: (schema.type or null) == "object";

  # Anything JSON can hold, narrowed to attribute sets for objects.
  untyped = schema: if isObject schema then types.attrsOf types.anything else types.anything;

  propertyOption =
    schema: name: property:
    let
      required = lib.elem name (schema.required or [ ]);
      type = schemaType property;
    in
    lib.mkOption (
      {
        type = if required then type else types.nullOr type;
        description = property.description or null;
      }
      // lib.optionalAttrs (!required) { default = null; }
    );

  objectType =
    schema:
    types.submodule (
      {
        options = lib.mapAttrs (propertyOption schema) schema.properties;
      }
      // lib.optionalAttrs (schema.x-kubernetes-preserve-unknown-fields or false) {
        freeformType = types.attrsOf types.anything;
      }
    );

  schemaType =
    schema:
    let
      type = schema.type or null;
      branches = schema.oneOf or [ ] ++ schema.anyOf or [ ];
    in
    if schema.x-kubernetes-int-or-string or false then
      types.either types.int types.str
    else if
      (
        schema.x-kubernetes-embedded-resource or false
        || schema.x-kubernetes-preserve-unknown-fields or false
      )
      && !(schema ? properties)
    then
      untyped schema
    else if schema ? enum then
      types.enum schema.enum
    # Next to a `type`, oneOf/anyOf only add value validations (structural
    # schemas may not declare types inside them), so the type decides.
    else if branches != [ ] && type == null then
      types.oneOf (map schemaType branches)
    else if type == "string" then
      types.str
    else if type == "integer" then
      types.int
    else if type == "number" then
      types.number
    else if type == "boolean" then
      types.bool
    else if type == "array" then
      types.listOf (if schema ? items then schemaType schema.items else types.anything)
    else if type == "object" && schema ? properties then
      objectType schema
    else if type == "object" && lib.isAttrs (schema.additionalProperties or null) then
      types.attrsOf (schemaType schema.additionalProperties)
    else
      untyped schema;
in
{
  inherit schemaType;
}
