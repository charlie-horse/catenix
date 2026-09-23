# `lib/render.nix`, pure part: resource configs -> manifests.
{ lib, catenix, ... }:
let
  inherit (catenix.render)
    stripNulls
    apiVersion
    toManifest
    manifestsFromResources
    ;
  inherit (lib) mkOption types;

  optional =
    type:
    mkOption {
      type = types.nullOr type;
      default = null;
    };

  metadata = mkOption {
    type = types.submodule {
      options = {
        namespace = optional types.str;
        labels = optional (types.attrsOf types.str);
      };
    };
    default = { };
  };

  # A miniature of what `resourceModule` declares: unset optional fields are
  # `null`. Submodule configs don't carry `_module` (`evalModules` removes it
  # from `config`), so a `_module` key in one is user data.
  configMap = types.submodule {
    options = {
      inherit metadata;
      data = optional (types.attrsOf types.str);
      immutable = optional types.bool;
    };
  };

  deployment = types.submodule {
    options = {
      inherit metadata;
      spec = mkOption {
        type = types.submodule {
          options = {
            replicas = optional types.int;
            containers = mkOption {
              type = types.listOf (
                types.submodule {
                  options = {
                    name = mkOption { type = types.str; };
                    image = optional types.str;
                  };
                }
              );
              default = [ ];
            };
          };
        };
        default = { };
      };
    };
  };

  # `config.resources` of these definitions, with the kinds above declared.
  resourcesOf =
    definitions:
    (lib.evalModules {
      modules = [
        {
          options.resources = mkOption {
            type = types.submodule {
              options.core.v1.ConfigMap = mkOption {
                type = types.attrsOf configMap;
                default = { };
              };
              options.apps.v1.Deployment = mkOption {
                type = types.attrsOf deployment;
                default = { };
              };
              options.batch.v1.Job = mkOption {
                type = types.attrsOf types.anything;
                default = { };
              };
            };
            default = { };
          };
        }
        definitions
      ];
    }).config.resources;

  config.resources = resourcesOf {
    resources.core.v1.ConfigMap.settings = {
      metadata.namespace = "default";
      data.key = "value";
    };
    resources.apps.v1.Deployment.web.spec.containers = [ { name = "web"; } ];
  };

  # `_module` as a key of user data (a valid ConfigMap key), in a submodule
  # config.
  moduleKeyResources = resourcesOf {
    resources.core.v1.ConfigMap.reserved.data._module = "kept";
    resources.apps.v1.Deployment.web.spec.containers = [ { name = "web"; } ];
  };
in
{
  # stripNulls

  testStripNullsDropsNullAttrs = {
    expr = stripNulls {
      a = 1;
      b = null;
    };
    expected = {
      a = 1;
    };
  };

  testStripNullsNested = {
    expr = stripNulls {
      a = {
        b = null;
        c.d = null;
        e = 2;
      };
    };
    expected = {
      a = {
        c = { };
        e = 2;
      };
    };
  };

  testStripNullsInsideLists = {
    expr = stripNulls {
      xs = [
        {
          a = null;
          b = 1;
        }
        [ { c = null; } ]
      ];
    };
    expected = {
      xs = [
        { b = 1; }
        [ { } ]
      ];
    };
  };

  testStripNullsKeepsFalsyValues = {
    expr = stripNulls {
      a = false;
      b = 0;
      c = "";
      d = [ ];
      e = { };
    };
    expected = {
      a = false;
      b = 0;
      c = "";
      d = [ ];
      e = { };
    };
  };

  testStripNullsKeepsNullListElements = {
    expr = stripNulls [
      null
      1
    ];
    expected = [
      null
      1
    ];
  };

  testStripNullsScalars = {
    expr = map stripNulls [
      null
      "s"
      3
      true
    ];
    expected = [
      null
      "s"
      3
      true
    ];
  };

  # apiVersion

  testApiVersionEmptyGroup = {
    expr = apiVersion {
      group = "";
      version = "v1";
    };
    expected = "v1";
  };

  testApiVersionCoreGroup = {
    expr = apiVersion {
      group = "core";
      version = "v1";
    };
    expected = "v1";
  };

  testApiVersionNamedGroup = {
    expr = apiVersion {
      group = "apps";
      version = "v1";
    };
    expected = "apps/v1";
  };

  testApiVersionDottedGroup = {
    expr = apiVersion {
      group = "example.io";
      version = "v1beta1";
    };
    expected = "example.io/v1beta1";
  };

  testApiVersionAcceptsResourceRecord = {
    expr = apiVersion {
      group = "apps";
      version = "v1";
      kind = "Deployment";
      namespaced = true;
      schema = { };
      definitions = { };
    };
    expected = "apps/v1";
  };

  # toManifest

  testToManifestInjectsIdentity = {
    expr = toManifest {
      apiVersion = "apps/v1";
      kind = "Deployment";
      name = "web";
      body = {
        metadata.namespace = "default";
        spec.replicas = 2;
      };
    };
    expected = {
      apiVersion = "apps/v1";
      kind = "Deployment";
      metadata = {
        name = "web";
        namespace = "default";
      };
      spec.replicas = 2;
    };
  };

  testToManifestWithoutMetadata = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "settings";
      body.data.key = "value";
    };
    expected = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata.name = "settings";
      data.key = "value";
    };
  };

  testToManifestNullMetadata = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "settings";
      body.metadata = null;
    };
    expected = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata.name = "settings";
    };
  };

  testToManifestEmptyBody = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "Namespace";
      name = "apps";
      body = { };
    };
    expected = {
      apiVersion = "v1";
      kind = "Namespace";
      metadata.name = "apps";
    };
  };

  testToManifestInjectedFieldsWin = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "right";
      body = {
        apiVersion = "wrong/v0";
        kind = "Wrong";
        metadata = {
          name = "wrong";
          labels.app = "demo";
        };
      };
    };
    expected = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "right";
        labels.app = "demo";
      };
    };
  };

  testToManifestStripsNullsDeep = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "Pod";
      name = "p";
      body = {
        metadata.namespace = null;
        spec = {
          hostname = null;
          containers = [
            {
              name = "c";
              image = null;
              env = [
                {
                  name = "A";
                  value = null;
                }
              ];
            }
          ];
        };
      };
    };
    expected = {
      apiVersion = "v1";
      kind = "Pod";
      metadata.name = "p";
      spec.containers = [
        {
          name = "c";
          env = [ { name = "A"; } ];
        }
      ];
    };
  };

  # `_module` is only special in module definitions; in a manifest it's data.
  testToManifestKeepsModuleKeys = {
    expr = toManifest {
      apiVersion = "example.io/v1";
      kind = "Gizmo";
      name = "g";
      body = {
        _module = "top";
        metadata.annotations._module = "annotation";
        data._module = "value";
        spec = {
          _module.check = true;
          items = [
            {
              _module = { };
              name = "a";
            }
          ];
        };
      };
    };
    expected = {
      apiVersion = "example.io/v1";
      kind = "Gizmo";
      metadata = {
        name = "g";
        annotations._module = "annotation";
      };
      _module = "top";
      data._module = "value";
      spec = {
        _module.check = true;
        items = [
          {
            _module = { };
            name = "a";
          }
        ];
      };
    };
  };

  testToManifestFromSubmoduleConfig = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "settings";
      body = config.resources.core.v1.ConfigMap.settings;
    };
    expected = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata = {
        name = "settings";
        namespace = "default";
      };
      data.key = "value";
    };
  };

  testToManifestKeepsModuleKeysOfSubmoduleConfig = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "ConfigMap";
      name = "reserved";
      body = moduleKeyResources.core.v1.ConfigMap.reserved;
    };
    expected = {
      apiVersion = "v1";
      kind = "ConfigMap";
      metadata.name = "reserved";
      data._module = "kept";
    };
  };

  # manifestsFromResources

  testManifestsFromResourcesEmpty = {
    expr = manifestsFromResources { };
    expected = [ ];
  };

  testManifestsFromResourcesPlainAttrs = {
    expr = manifestsFromResources {
      core.v1.ConfigMap.settings.data.key = "value";
      "example.io".v1.Gizmo.heavy.weight = 2.5;
    };
    expected = [
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata.name = "settings";
        data.key = "value";
      }
      {
        apiVersion = "example.io/v1";
        kind = "Gizmo";
        metadata.name = "heavy";
        weight = 2.5;
      }
    ];
  };

  testManifestsFromResourcesSorted = {
    expr = map (m: "${m.apiVersion} ${m.kind} ${m.metadata.name}") (manifestsFromResources {
      core.v1.ConfigMap.b = { };
      core.v1.ConfigMap.a = { };
      batch.v1.Job.j = { };
      apps.v1beta1.Deployment.old = { };
      apps.v1.StatefulSet.db = { };
      apps.v1.Deployment.web = { };
      apps.v1.Deployment.api = { };
      "example.io".v1.Gizmo.g = { };
    });
    expected = [
      "apps/v1 Deployment api"
      "apps/v1 Deployment web"
      "apps/v1 StatefulSet db"
      "apps/v1beta1 Deployment old"
      "batch/v1 Job j"
      "v1 ConfigMap a"
      "v1 ConfigMap b"
      "example.io/v1 Gizmo g"
    ];
  };

  # A fresh `kubectl apply -f` creates objects in file order, so namespaces
  # come first (namespaced objects need them), then CRDs (custom resources
  # need them), each in the usual order. Only the real kinds: a custom kind
  # named `Namespace` is an ordinary custom resource.
  testManifestsFromResourcesNamespacesThenCrdsFirst = {
    expr = map (m: "${m.apiVersion} ${m.kind} ${m.metadata.name}") (manifestsFromResources {
      core.v1.ConfigMap.settings = { };
      core.v1.Namespace.b = { };
      core.v1.Namespace.a = { };
      apps.v1.Deployment.web = { };
      "apiextensions.k8s.io".v1.CustomResourceDefinition."widgets.example.io" = { };
      "apiextensions.k8s.io".v1.CustomResourceDefinition."gizmos.example.io" = { };
      "example.io".v1.Gizmo.g = { };
      "example.io".v1.Namespace.custom = { };
      batch.v1.Job.j = { };
    });
    expected = [
      "v1 Namespace a"
      "v1 Namespace b"
      "apiextensions.k8s.io/v1 CustomResourceDefinition gizmos.example.io"
      "apiextensions.k8s.io/v1 CustomResourceDefinition widgets.example.io"
      "apps/v1 Deployment web"
      "batch/v1 Job j"
      "v1 ConfigMap settings"
      "example.io/v1 Gizmo g"
      "example.io/v1 Namespace custom"
    ];
  };

  testManifestsFromResourcesNamespaceOfEmptyGroupFirst = {
    expr = map (m: "${m.apiVersion} ${m.kind} ${m.metadata.name}") (manifestsFromResources {
      "".v1.Namespace.apps = { };
      "apiextensions.k8s.io".v1.CustomResourceDefinition."widgets.example.io" = { };
      apps.v1.Deployment.web = { };
    });
    expected = [
      "v1 Namespace apps"
      "apiextensions.k8s.io/v1 CustomResourceDefinition widgets.example.io"
      "apps/v1 Deployment web"
    ];
  };

  testManifestsFromResourcesModuleConfig = {
    expr = manifestsFromResources config.resources;
    expected = [
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata.name = "web";
        spec.containers = [ { name = "web"; } ];
      }
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "settings";
          namespace = "default";
        };
        data.key = "value";
      }
    ];
  };

  testManifestsFromResourcesIsPlainData = {
    expr = builtins.toJSON (manifestsFromResources config.resources);
    expected = builtins.toJSON [
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata.name = "web";
        spec.containers = [ { name = "web"; } ];
      }
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata = {
          name = "settings";
          namespace = "default";
        };
        data.key = "value";
      }
    ];
  };

  # Submodule configs (the ConfigMap, the Deployment and its containers) add
  # no `_module` of their own, and the user's `_module` key survives; plain
  # enough for `toJSON`, which would choke on `_module.args`' functions.
  testManifestsFromResourcesKeepsModuleKeysOfModuleConfig = {
    expr = builtins.toJSON (manifestsFromResources moduleKeyResources);
    expected = builtins.toJSON [
      {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata.name = "web";
        spec.containers = [ { name = "web"; } ];
      }
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata.name = "reserved";
        data._module = "kept";
      }
    ];
  };

  testManifestsFromResourcesSkipsNullInstances = {
    expr = manifestsFromResources {
      core.v1.ConfigMap = {
        gone = null;
        kept = { };
      };
    };
    expected = [
      {
        apiVersion = "v1";
        kind = "ConfigMap";
        metadata.name = "kept";
      }
    ];
  };
}
