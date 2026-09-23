# Maps one normalized JSON schema (no `$ref`/`allOf`) to a `lib.types` value.
#
# Object properties become submodule options built lazily with `mapAttrs`, so
# nested types exist only once something (a definition, the docs) asks for them.
# Constraint keywords are read only when a value is checked or the description
# is shown.
{ lib, catenix }:
let
  inherit (lib) types;
  inherit (catenix) utf8 pattern stringFormat;

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

  # "at most 3 items", "between 1 and 2 items", "exactly 1 item", ...
  countPhrase =
    noun: nouns: min: max:
    let
      count = n: "${toString n} ${if n == 1 then noun else nouns}";
    in
    if min != null && max != null then
      if min == max then
        "exactly ${count min}"
      else
        "between ${toString min} and ${toString max} ${nouns}"
    else if min != null then
      "at least ${count min}"
    else
      "at most ${count max}";

  # A schema's count limits (`minLength`/`maxLength`, ...) as `{ min, max }`,
  # null where absent; a zero minimum limits nothing.
  countLimits =
    minKey: maxKey: schema:
    let
      min = schema.${minKey} or 0;
    in
    {
      min = if min > 0 then min else null;
      max = schema.${maxKey} or null;
      any = min > 0 || schema ? ${maxKey};
    };

  withinCount =
    limits: n: (limits.min == null || n >= limits.min) && (limits.max == null || n <= limits.max);

  # Checks are `{ phrase, check, failure }`: the description's words, a
  # predicate, and (for merged values) what a failing value "has".
  describeChecks = checks: lib.concatMapStringsSep ", " (c: c.phrase) checks;

  # `base` with checks on each value (a string can't be merged from parts),
  # described as "<noun> <phrases> (<notes>)".
  checkedEach =
    base: noun: checks: notes:
    types.addCheck base (x: lib.all (c: c.check x) checks)
    // {
      description =
        noun
        + lib.optionalString (checks != [ ]) " ${describeChecks checks}"
        + lib.concatMapStrings (note: " (${note})") notes;
    };

  # `base` with checks on its merged value: lists concatenate and attribute
  # sets merge across definitions, so each definition passing isn't enough.
  # Wraps the module system's v2 merge, so failures read like its own type
  # errors. The module system rebuilds types holding submodules with
  # `substSubModules` when declaring an option, so that keeps the checks.
  checkedMerged =
    base: checks:
    let
      substSubModules = modules: checkedMerged (base.substSubModules modules) checks;
      description = "${base.description} ${describeChecks checks}";
      failing = value: lib.findFirst (c: !(c.check value)) null checks;
      headError =
        value:
        let
          c = failing value;
        in
        if c == null then null else { message = "The merged value ${c.failure value}."; };
    in
    if checks == [ ] then
      base
    else if !(base.merge ? v2) then
      types.addCheck base (x: failing x == null) // { inherit description substSubModules; }
    else
      base
      // {
        inherit description substSubModules;
        merge = {
          __functor =
            self: loc: defs:
            let
              merged = self.v2 { inherit loc defs; };
            in
            if merged.headError != null then
              throw "A definition for option `${lib.showOption loc}' is not of type `${description}'. TypeError: ${merged.headError.message}"
            else
              merged.value;
          v2 =
            args:
            let
              merged = base.merge.v2 args;
            in
            merged
            // {
              headError = if merged.headError != null then merged.headError else headError merged.value;
            };
        };
      };

  # minLength/maxLength (in characters, as Kubernetes counts them), a
  # checked `format` and a translatable `pattern`, cheapest first.
  stringChecks =
    schema:
    let
      limits = countLimits "minLength" "maxLength" schema;
      # A string has at most as many characters as bytes, and at least a
      # quarter as many, so most values are never counted.
      lengthOk =
        s:
        let
          bytes = builtins.stringLength s;
          fitsMax = limits.max == null || bytes <= limits.max || utf8.length s <= limits.max;
          fitsMin =
            limits.min == null
            || (bytes >= limits.min && (bytes >= 4 * limits.min || utf8.length s >= limits.min));
        in
        fitsMax && fitsMin;
      formatCheck = stringFormat.check schema.format;
      matches = pattern.matcher schema.pattern;
    in
    lib.optional limits.any {
      phrase = "${countPhrase "character" "characters" limits.min limits.max} long";
      check = lengthOk;
    }
    ++ lib.optional (schema ? format && formatCheck != null) {
      phrase = "in ${schema.format} format";
      check = formatCheck;
    }
    ++ lib.optional (schema ? pattern && matches != null) {
      phrase = "matching the pattern `${schema.pattern}`";
      check = matches;
    };

  stringType =
    schema:
    if schema ? minLength || schema ? maxLength || schema ? format || schema ? pattern then
      checkedEach types.str "string" (stringChecks schema) (
        lib.optional (
          schema ? pattern && pattern.matcher schema.pattern == null
        ) "pattern `${schema.pattern}` not checked"
      )
    else
      types.str;

  itemChecks =
    schema:
    let
      limits = countLimits "minItems" "maxItems" schema;
    in
    lib.optional limits.any {
      phrase = "with ${countPhrase "item" "items" limits.min limits.max}";
      check = list: withinCount limits (builtins.length list);
      failure = list: "has ${toString (builtins.length list)} items";
    }
    ++ lib.optional (schema.uniqueItems or false) {
      phrase = "without duplicates";
      check = list: builtins.length (lib.unique list) == builtins.length list;
      failure = _: "has duplicate items";
    };

  arrayType =
    schema:
    let
      list = types.listOf (if schema ? items then schemaType schema.items else types.anything);
    in
    if schema ? minItems || schema ? maxItems || schema ? uniqueItems then
      checkedMerged list (itemChecks schema)
    else
      list;

  # Kubernetes counts the keys it receives; unset (null) properties are
  # dropped when rendering.
  propertyCount = attrs: builtins.length (lib.filter (v: v != null) (builtins.attrValues attrs));

  # minProperties/maxProperties on an object type.
  withPropertyCounts =
    schema: base:
    let
      limits = countLimits "minProperties" "maxProperties" schema;
    in
    if schema ? minProperties || schema ? maxProperties then
      checkedMerged base (
        lib.optional limits.any {
          phrase = "with ${countPhrase "property" "properties" limits.min limits.max}";
          check = attrs: withinCount limits (propertyCount attrs);
          failure = attrs: "has ${toString (propertyCount attrs)} properties";
        }
      )
    else
      base;

  untypedType =
    schema: if isObject schema then withPropertyCounts schema (untyped schema) else untyped schema;

  schemaType =
    schema:
    let
      type = schema.type or null;
      branches = schema.oneOf or [ ] ++ schema.anyOf or [ ];
    in
    if schema.x-kubernetes-int-or-string or false then
      types.either types.int (stringType schema)
    else if
      (
        schema.x-kubernetes-embedded-resource or false
        || schema.x-kubernetes-preserve-unknown-fields or false
      )
      && !(schema ? properties)
    then
      untypedType schema
    else if schema ? enum then
      types.enum schema.enum
    # Next to a `type`, oneOf/anyOf only add value validations (structural
    # schemas may not declare types inside them), so the type decides.
    else if branches != [ ] && type == null then
      types.oneOf (map schemaType branches)
    else if type == "string" then
      stringType schema
    else if type == "integer" then
      integerType schema
    else if type == "number" then
      numberType schema
    else if type == "boolean" then
      types.bool
    else if type == "array" then
      arrayType schema
    else if type == "object" && schema ? properties then
      withPropertyCounts schema (objectType schema)
    else if type == "object" && lib.isAttrs (schema.additionalProperties or null) then
      withPropertyCounts schema (types.attrsOf (schemaType schema.additionalProperties))
    else
      untypedType schema;
in
{
  inherit schemaType;
}
