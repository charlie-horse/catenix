# Unit tests for modules/resources.nix and modules/build.nix: the `resources`
# option (freeform unless strict, merged with `resourceModule`-style kind
# declarations) and the read-only `build` outputs wired to lib/render.nix.
# `build.yaml` is only checked as a derivation: reading it back would be
# import-from-derivation, which this suite's sandboxed runner can't do.
{
  lib,
  catenix,
  pkgs,
  helpers,
  ...
}:
let
  inherit (lib) mkOption types;

  eval =
    modules:
    helpers.eval pkgs (
      [
        ../../modules/resources.nix
        ../../modules/build.nix
      ]
      ++ modules
    );

  manifestsOf = modules: (eval modules).config.build.manifests;
  failsWith = modules: helpers.fails (manifestsOf modules);

  strict = {
    validation.strict = true;
  };

  # Stand-ins for what `resourceModule.mkResourceModule` declares: each kind an
  # option nested under its group and version inside a `resources` submodule.
  # They set only `type`; `default` and `description` of `resources` belong to
  # modules/resources.nix, and the module system allows just one of each.
  declareKind = group: version: kind: options: {
    options.resources = mkOption {
      type = types.submodule {
        options.${group}.${version}.${kind} = mkOption {
          type = types.attrsOf (types.submodule { inherit options; });
          default = { };
        };
      };
    };
  };

  gadgetModule = declareKind "core" "v1" "Gadget" {
    size = mkOption { type = types.int; };
    color = mkOption {
      type = types.nullOr types.str;
      default = null;
    };
  };

  widgetModule = declareKind "example.com" "v1" "Widget" {
    label = mkOption { type = types.str; };
  };

  smallGadget = {
    resources.core.v1.Gadget.small.size = 1;
  };

  smallGadgetManifest = {
    apiVersion = "v1";
    kind = "Gadget";
    metadata.name = "small";
    size = 1;
  };

  unknownThing = {
    resources."example.io".v1beta1.Thing.one.spec.replicas = 2;
  };

  unknownThingManifest = {
    apiVersion = "example.io/v1beta1";
    kind = "Thing";
    metadata.name = "one";
    spec.replicas = 2;
  };

  unknownKindInCoreV1 = {
    resources.core.v1.Unknown.thing.anything = 1;
  };

  unknownKindInCoreV1Manifest = {
    apiVersion = "v1";
    kind = "Unknown";
    metadata.name = "thing";
    anything = 1;
  };

  unknownVersionOfCore = {
    resources.core.v2.Gadget.next.size = "untyped";
  };

  unknownVersionOfCoreManifest = {
    apiVersion = "v2";
    kind = "Gadget";
    metadata.name = "next";
    size = "untyped";
  };
in
{
  # validation.strict

  testStrictOffByDefault = {
    expr = (eval [ ]).config.validation.strict;
    expected = false;
  };

  # kinds: scopes of declared kinds, filled in by `resourceModule` modules

  testNoKindsDeclared = {
    expr = (eval [ ]).config.kinds;
    expected = { };
  };

  # resources, with no kinds declared

  testNoResourcesNoManifests = {
    expr = manifestsOf [ ];
    expected = [ ];
  };

  testUnknownGroupAcceptedByDefault = {
    expr = manifestsOf [ unknownThing ];
    expected = [ unknownThingManifest ];
  };

  testUnknownGroupRejectedWhenStrict = {
    expr = failsWith [
      strict
      unknownThing
    ];
    expected = true;
  };

  testUnknownResourceDefinitionsMerge = {
    expr = manifestsOf [
      { resources."example.io".v1.Thing.one.a = 1; }
      { resources."example.io".v1.Thing.one.b = 2; }
    ];
    expected = [
      {
        apiVersion = "example.io/v1";
        kind = "Thing";
        metadata.name = "one";
        a = 1;
        b = 2;
      }
    ];
  };

  testUnknownResourceBodyMustBeAttrs = {
    expr = failsWith [ { resources."example.io".v1.Thing.one = 5; } ];
    expected = true;
  };

  testUnknownResourceTooShallowFails = {
    expr = failsWith [ { resources."example.io".v1.Thing = "one"; } ];
    expected = true;
  };

  # resources, merged with declared kinds

  testDeclaredKindRendered = {
    expr = manifestsOf [
      gadgetModule
      smallGadget
    ];
    expected = [ smallGadgetManifest ];
  };

  testDeclaredKindTypeChecked = {
    expr = failsWith [
      gadgetModule
      { resources.core.v1.Gadget.bad.size = "big"; }
    ];
    expected = true;
  };

  testDeclaredKindRejectsUnknownFieldWhenNotStrict = {
    expr = failsWith [
      gadgetModule
      {
        resources.core.v1.Gadget.bad = {
          size = 1;
          shape = "round";
        };
      }
    ];
    expected = true;
  };

  testDeclaredKindAcceptedWhenStrict = {
    expr = manifestsOf [
      gadgetModule
      strict
      smallGadget
    ];
    expected = [ smallGadgetManifest ];
  };

  testUnknownKindInDeclaredVersionAccepted = {
    expr = manifestsOf [
      gadgetModule
      smallGadget
      unknownKindInCoreV1
    ];
    expected = [
      smallGadgetManifest
      unknownKindInCoreV1Manifest
    ];
  };

  testUnknownKindInDeclaredVersionRejectedWhenStrict = {
    expr = failsWith [
      gadgetModule
      strict
      smallGadget
      unknownKindInCoreV1
    ];
    expected = true;
  };

  testUnknownVersionOfDeclaredGroupAccepted = {
    expr = manifestsOf [
      gadgetModule
      smallGadget
      unknownVersionOfCore
    ];
    expected = [
      smallGadgetManifest
      unknownVersionOfCoreManifest
    ];
  };

  testUnknownVersionOfDeclaredGroupRejectedWhenStrict = {
    expr = failsWith [
      gadgetModule
      strict
      smallGadget
      unknownVersionOfCore
    ];
    expected = true;
  };

  testUnknownGroupBesideDeclaredAccepted = {
    expr = manifestsOf [
      gadgetModule
      smallGadget
      unknownThing
    ];
    expected = [
      smallGadgetManifest
      unknownThingManifest
    ];
  };

  testUnknownGroupBesideDeclaredRejectedWhenStrict = {
    expr = failsWith [
      gadgetModule
      strict
      smallGadget
      unknownThing
    ];
    expected = true;
  };

  testDeclarationsFromSeveralModulesMerge = {
    expr = manifestsOf [
      gadgetModule
      widgetModule
      strict
      smallGadget
      { resources."example.com".v1.Widget.w.label = "x"; }
    ];
    expected = [
      smallGadgetManifest
      {
        apiVersion = "example.com/v1";
        kind = "Widget";
        metadata.name = "w";
        label = "x";
      }
    ];
  };

  # build

  testManifestsReadOnly = {
    expr = failsWith [ { build.manifests = [ ]; } ];
    expected = true;
  };

  testYamlIsDerivation = {
    expr = lib.isDerivation (eval [ ]).config.build.yaml;
    expected = true;
  };

  testYamlRendersManifests =
    let
      inherit
        (eval [
          gadgetModule
          smallGadget
          unknownThing
        ])
        config
        ;
    in
    {
      expr = config.build.yaml.drvPath;
      expected = (catenix.render.toYaml pkgs config.build.manifests).drvPath;
    };

  testYamlReadOnly = {
    expr = helpers.fails (eval [ { build.yaml = pkgs.emptyFile; } ]).config.build.yaml.name;
    expected = true;
  };
}
