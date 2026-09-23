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

  # A miniature of what `resourceModule` declares: submodule configs carry
  # `_module`, and unset optional fields are `null`.
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

  inherit
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
        {
          resources.core.v1.ConfigMap.settings = {
            metadata.namespace = "default";
            data.key = "value";
          };
          resources.apps.v1.Deployment.web.spec.containers = [ { name = "web"; } ];
        }
      ];
    })
    config
    ;
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

  testToManifestStripsNullsAndModuleAttrsDeep = {
    expr = toManifest {
      apiVersion = "v1";
      kind = "Pod";
      name = "p";
      body = {
        _module.args = { };
        metadata = {
          _module.check = true;
          namespace = null;
        };
        spec = {
          _module.freeformType = null;
          hostname = null;
          containers = [
            {
              _module.args = { };
              name = "c";
              image = null;
              env = [
                {
                  _module = { };
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
