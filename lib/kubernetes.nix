# Resource schema records for the built-in Kubernetes API, from parsed OpenAPI
# v3 documents (`api/openapi-spec/v3/*.json`) and, optionally, aggregated
# discovery (`api/discovery/aggregated_v2.json`) for resource scopes.
{ lib }:
let
  inherit (lib)
    concatLists
    concatMap
    concatStringsSep
    filter
    hasSuffix
    mapAttrsToList
    ;

  gvkKey =
    {
      group,
      version,
      kind,
      ...
    }:
    "${group}/${version}/${kind}";

  showGvk =
    {
      group,
      version,
      kind,
      ...
    }:
    "${if group == "" then version else "${group}/${version}"} ${kind}";

  # Resource collection paths: `/api/<v>/<plural>`, `/apis/<g>/<v>/<plural>`
  # and their `namespaces/{namespace}/<plural>` forms.
  segment = "[^/{}]+";
  groupVersion = "/(api|apis/${segment})/${segment}";
  clusterPath = "${groupVersion}/${segment}";
  namespacedPath = "${groupVersion}/namespaces/[{]namespace[}]/${segment}";

  # Whether a path is a namespaced (true) or cluster-wide (false) collection;
  # null for any other path.
  pathScope =
    path:
    if builtins.match namespacedPath path != null then
      true
    else if builtins.match clusterPath path != null then
      false
    else
      null;

  # GVK key -> namespaced, from a document's `paths`. Namespaced kinds are also
  # listed across all namespaces at cluster-wide paths, so any namespaced path
  # makes a kind namespaced.
  pathScopes =
    paths:
    let
      operations = concatLists (
        mapAttrsToList (
          path: item:
          let
            namespaced = pathScope path;
            # Path items also hold non-operation keys such as `parameters`.
            gvks = builtins.catAttrs "x-kubernetes-group-version-kind" (
              filter builtins.isAttrs (builtins.attrValues item)
            );
          in
          lib.optionals (namespaced != null) (
            map (gvk: {
              key = gvkKey gvk;
              inherit namespaced;
            }) gvks
          )
        ) paths
      );
    in
    builtins.mapAttrs (_: builtins.any (op: op.namespaced)) (builtins.groupBy (op: op.key) operations);

  # GVK key -> namespaced, from discovery's top-level resources. An empty
  # `responseKind` group or version means the enclosing group or version.
  discoveryScopes =
    discovery:
    lib.listToAttrs (
      concatMap (
        item:
        concatMap (
          entry:
          map (
            resource:
            let
              inherit (resource) responseKind;
              scope = resource.scope or "";
              gvk = {
                group = if responseKind.group or "" != "" then responseKind.group else item.metadata.name or "";
                version = if responseKind.version or "" != "" then responseKind.version else entry.version;
                inherit (responseKind) kind;
              };
            in
            lib.nameValuePair (gvkKey gvk) (
              if scope == "Namespaced" then
                true
              else if scope == "Cluster" then
                false
              else
                throw "catenix.kubernetes.loadKubernetes: unknown discovery scope \"${scope}\" for ${showGvk gvk}"
            )
          ) (filter (resource: resource ? responseKind.kind) (entry.resources or [ ]))
        ) (item.versions or [ ])
      ) (discovery.items or [ ])
    );

  # Records for one document's kinds, skipping `*List` kinds and kinds without
  # a known scope. Discovery only decides scopes for named groups.
  documentRecords =
    discoveryScope: document:
    let
      definitions = document.components.schemas or { };
      pathScope' = pathScopes (document.paths or { });
      scopeOf =
        gvk:
        let
          key = gvkKey gvk;
        in
        if gvk.group != "" && discoveryScope ? ${key} then
          discoveryScope.${key}
        else
          pathScope'.${key} or null;
    in
    concatLists (
      mapAttrsToList (
        _: schema:
        concatMap (
          gvk:
          let
            namespaced = scopeOf gvk;
          in
          lib.optional (!hasSuffix "List" gvk.kind && namespaced != null) {
            inherit (gvk) group version kind;
            inherit namespaced schema definitions;
          }
        ) (lib.toList (schema.x-kubernetes-group-version-kind or [ ]))
      ) definitions
    );
in
{
  loadKubernetes =
    {
      openapi,
      discovery ? null,
    }:
    let
      discoveryScope = if discovery == null then { } else discoveryScopes discovery;
      records = concatMap (documentRecords discoveryScope) openapi;
      duplicates = filter (group: builtins.length group > 1) (
        builtins.attrValues (builtins.groupBy gvkKey records)
      );
    in
    if records == [ ] then
      throw "catenix.kubernetes.loadKubernetes: no resources found in the OpenAPI documents"
    else if duplicates != [ ] then
      throw "catenix.kubernetes.loadKubernetes: duplicate resources: ${
        concatStringsSep ", " (map (group: showGvk (builtins.head group)) duplicates)
      }"
    else
      records;
}
