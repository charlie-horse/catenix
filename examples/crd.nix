# A custom resource: the `CronTab` CRD from the Kubernetes docs, imported from
# its YAML, and one `CronTab`. `pkgs` and `catenix` (the flake's `lib`) come
# from `specialArgs`, so they can be used in `imports`. With
# `validation.strict`, resources of kinds no imported schema declares (say, a
# typo in the group or kind) are errors instead of passing through untyped.
# Render it with:
#
#   nix run .#render -- examples/crd.nix
{ pkgs, catenix, ... }:
{
  imports = [
    (catenix.importCrdModule {
      inherit pkgs;
      crdFile = ./crontab-crd.yaml;
    })
  ];

  validation.strict = true;

  resources."stable.example.com".v1.CronTab.my-new-cron-object = {
    metadata.namespace = "default";
    spec = {
      cronSpec = "* * * * */5";
      image = "my-awesome-cron-image";
      replicas = 1;
    };
  };
}
