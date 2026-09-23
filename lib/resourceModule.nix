# Resource schema records -> a module declaring typed resources.
#
# `mkResourceModule resources` declares
# `resources.<group>.<version>.<Kind>.<name>` (core group spelled `core`) as a
# submodule, so the declarations of several such modules (core types, each
# imported CRD) and of modules/resources.nix merge. Each instance is typed by
# its kind's normalized schema minus the fields `render` injects: `apiVersion`,
# `kind`, `metadata.name`, and `metadata.namespace` for cluster-scoped kinds.
# Types are built lazily: until a kind is used, only the top level of its
# schema is looked at (the module system asks whether instances are
# submodules).
{ lib, catenix }:
let
  inherit (lib) mkOption types;
  inherit (catenix.normalize) normalize;
  inherit (catenix.schemaType) schemaType;

  groupKey = group: if group == "" then "core" else group;

  # A property no value satisfies; being optional it maps to `nullOr`, so it
  # can only be left unset.
  forbidden = {
    enum = [ ];
    description = "Set by catenix when rendering.";
  };

  # The object `schema` without the properties `names`, which are also dropped
  # from `required`. An object that accepts unknown fields (no properties, or
  # `x-kubernetes-preserve-unknown-fields`) declares them `forbidden` instead,
  # so its freeform part can't take them.
  withoutFields =
    names: schema:
    let
      open = !(schema ? properties) || schema.x-kubernetes-preserve-unknown-fields or false;
    in
    schema
    // {
      type = "object";
      properties =
        removeAttrs (schema.properties or { }) names
        // lib.optionalAttrs open (lib.genAttrs names (_: forbidden));
      required = lib.subtractLists names (schema.required or [ ]);
    }
    // lib.optionalAttrs open { x-kubernetes-preserve-unknown-fields = true; };

  # A kind's normalized schema as an instance schema. Every kind has
  # `metadata`; CRDs usually declare it as a bare `type: object`.
  instanceSchema =
    namespaced: schema:
    let
      top = withoutFields [ "apiVersion" "kind" ] schema;
      metadata = schema.properties.metadata or { type = "object"; };
    in
    top
    // {
      properties = top.properties // {
        metadata = withoutFields ([ "name" ] ++ lib.optional (!namespaced) "namespace") metadata;
      };
    };

  instanceType =
    resource:
    schemaType (instanceSchema resource.namespaced (normalize resource.definitions resource.schema));

  kindModule =
    resource@{
      group,
      version,
      kind,
      ...
    }:
    {
      options.${groupKey group}.${version}.${kind} = mkOption {
        type = types.attrsOf (instanceType resource);
        default = { };
        description = (normalize resource.definitions resource.schema).description or null;
      };
    };
in
{
  inherit instanceType;

  # No `default`/`description` here: other declarations of `resources` merge
  # with this one, and only one of them may set those.
  mkResourceModule = resources: {
    options.resources = mkOption {
      type = types.submodule { imports = map kindModule resources; };
    };
  };
}
