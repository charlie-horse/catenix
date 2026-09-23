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

  # A schema's `minimum` (or `maximum`) as a list of `{ value, exclusive }`
  # bounds. OpenAPI v3.0, and so CRDs, makes it exclusive with a boolean
  # `exclusiveMinimum`; JSON Schema 2019-09 and OpenAPI 3.1 give an exclusive
  # bound of its own as a number there instead.
  bounds =
    key: exclusiveKey: schema:
    let
      exclusive = schema.${exclusiveKey} or false;
    in
    lib.optional (schema ? ${key}) {
      value = schema.${key};
      exclusive = exclusive == true;
    }
    ++ lib.optional (!lib.isBool exclusive) {
      value = exclusive;
      exclusive = true;
    };

  lowerBounds = bounds "minimum" "exclusiveMinimum";
  upperBounds = bounds "maximum" "exclusiveMaximum";

  # The tightest of some bounds (null for none): the one whose value is
  # `further` in, an exclusive one on a tie.
  tightest =
    further:
    lib.foldl' (
      a: b: if a == null || further b.value a.value || (b.value == a.value && b.exclusive) then b else a
    ) null;

  tightestLower = tightest (b: a: b > a);
  tightestUpper = tightest (b: a: b < a);

  withinBounds =
    lower: upper: x:
    (lower == null || (if lower.exclusive then x > lower.value else x >= lower.value))
    && (upper == null || (if upper.exclusive then x < upper.value else x <= upper.value));

  # "between 1 and 10 (both inclusive)" like `ints.between`, else e.g.
  # "greater than 0 and at most 1".
  describeBounds =
    lower: upper:
    let
      show = bound: builtins.toJSON bound.value;
      phrase =
        inclusive: exclusive: bound:
        "${if bound.exclusive then exclusive else inclusive} ${show bound}";
      both = if lower.exclusive then "exclusive" else "inclusive";
    in
    if lower != null && upper != null && lower.exclusive == upper.exclusive then
      "between ${show lower} and ${show upper} (both ${both})"
    else
      lib.concatStringsSep " and " (
        lib.optional (lower != null) (phrase "at least" "greater than" lower)
        ++ lib.optional (upper != null) (phrase "at most" "less than" upper)
      );

  # `base` restricted to the bounds; its description ("<noun> <bounds>") is
  # what module errors quote.
  bounded =
    base: noun: lower: upper:
    if lower == null && upper == null then
      base
    else
      types.addCheck base (withinBounds lower upper)
      // {
        description = "${noun} ${describeBounds lower upper}";
      };

  # Kubernetes decodes `format: int32` fields into Go int32s, which reject or
  # silently wrap larger values; `int64` (or no format) is what a Nix int is.
  int32Min = {
    value = -2147483648;
    exclusive = false;
  };
  int32Max = {
    value = 2147483647;
    exclusive = false;
  };

  integerType =
    schema:
    let
      int32 = (schema.format or null) == "int32";
      # For an integer, `> n` is `>= n + 1`, which reads (and combines) better.
      inclusive =
        step: bound:
        if bound.exclusive && lib.isInt bound.value then
          {
            value = bound.value + step;
            exclusive = false;
          }
        else
          bound;
      lower = map (inclusive 1) (lowerBounds schema);
      upper = map (inclusive (-1)) (upperBounds schema);
    in
    if int32 && lower == [ ] && upper == [ ] then
      types.ints.s32
    else
      bounded types.int "integer" (tightestLower (lower ++ lib.optional int32 int32Min)) (
        tightestUpper (upper ++ lib.optional int32 int32Max)
      );

  numberType =
    schema:
    bounded types.number "integer or floating point number" (tightestLower (lowerBounds schema)) (
      tightestUpper (upperBounds schema)
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
      integerType schema
    else if type == "number" then
      numberType schema
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
