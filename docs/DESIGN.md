# catenix design

Kubernetes manifests written as Nix, type-checked against the Kubernetes API
(and CRDs) by the module system. The Kubernetes OpenAPI v3 spec and CRD
`openAPIV3Schema` documents are parsed with `builtins.fromJSON` and walked by
pure Nix functions that build real `lib.types.*` values — the type *is* the
value; no generated source text.

Guiding rules: prefer native Nix/flake mechanisms; add a dependency only when
nothing native covers the need; one unit of responsibility per file; avoid
non-Nix code; strict TDD (see below).

## Flake outputs

| Output | Contents |
| --- | --- |
| `lib` | Every `lib/*.nix` unit, keyed by file name (`lib/default.nix`). System-agnostic: units that build derivations take `pkgs` as an argument. |
| `nixosModules.default` | `modules/resources.nix` + `modules/build.nix` + core Kubernetes types from the pinned `kubernetes-src`. Callers run their own `lib.evalModules` and must provide `pkgs` as a module argument (`_module.args.pkgs`). |
| `tests` | Every suite as nix-unit `{ expr, expected }` cases (`tests/default.nix`). Run one with `nix-unit --flake .#tests.unit.normalize`. |
| `checks.<system>` | One named check per suite (`tests/checks.nix`). |
| `apps.<system>.render` | `nix run .#render -- <flake-ref-to-an-evaluation>` prints its `config.build.yaml`. |
| `devShells.<system>.default` | `nix-unit`, `yq-go`, `nixfmt-rfc-style`, `jq`. |
| `formatter.<system>` | `nixfmt-rfc-style`. |

## Dependency policy

Flake inputs: `nixpkgs` and `kubernetes-src`. Everything else is a `builtins`
primop or comes from nixpkgs.

- **nix-unit** — test runner, taken from nixpkgs (`pkgs.nix-unit`) rather than
  as its own flake input. Checks wrap it in a `runCommand`, per nix-unit's
  flake example; no flake-composition framework.
- **yq-go** (nixpkgs) — Nix has no YAML parser and CRDs ship as YAML. Scoped to
  `lib/yaml2json.nix`.
- **`pkgs.formats.yaml`** (nixpkgs) — Nix has no YAML encoder. Scoped to
  `render.toYaml`.

No general-purpose flake framework: `lib.genAttrs` covers per-system outputs.

`kubernetes-src` is a `git+https://github.com/...?ref=refs/tags/<tag>&shallow=1`
input rather than `github:`: Kubernetes marks `hack/lib/version.sh` as
`export-subst`, so GitHub's tarball differs from the git tree, and the git
fetcher is the one that works everywhere (including sandboxed CI with only git
egress). Bump it by editing the tag and running `nix flake update kubernetes-src`.

## Checks: two runners, one test format

Pure suites run under nix-unit inside a derivation. Suites that read a
derivation's output back during evaluation (YAML→JSON, YAML encoding, CRD
import, anything asserting rendered YAML) can't build inside that sandbox, so
`tests/checks.nix` evaluates them during `nix flake check` itself with
`lib.debug.runTests`. Both runners read the same `{ expr, expected }` cases.
Failure cases use `helpers.fails value` (deep `tryEval`) with
`expected = true`, which works under both runners. Test names start with
`test`.

## Interfaces (the contract between units)

### Resource schema record

Produced by `kubernetes.nix` and `crd.nix`, consumed by `resourceModule.nix`:

```nix
{
  group = "apps";          # "" for the core group
  version = "v1";
  kind = "Deployment";
  namespaced = true;
  schema = { ... };         # the raw, un-normalized JSON Schema of the kind
  definitions = { ... };    # name -> schema, for resolving $ref ("{}" for CRDs)
}
```

Resource keys in `config.resources` are `<group>.<version>.<Kind>.<name>`, with
the core group spelled `core` (e.g. `resources.core.v1.ConfigMap.my-config`).

### `lib/normalize.nix` → `normalize.normalize definitions schema`

Resolves `$ref` (`#/components/schemas/<n>`, `#/definitions/<n>`, or bare
`<n>`) against `definitions`, merges `allOf` branches into one schema (merging
`properties` recursively, unioning `required`, later `description`/
`x-kubernetes-map-type` win, other conflicts throw), and recurses into
`properties`, `items`, object `additionalProperties`, `oneOf`, `anyOf`.
Sibling keys next to `$ref` are merged over the resolved target. A `$ref`
already being resolved further up the path yields
`{ type = "object"; x-kubernetes-preserve-unknown-fields = true; }` so
recursive schemas terminate. Unresolvable refs throw. Lazy: nested schemas are
only normalized when forced.

### `lib/schemaType.nix` → `schemaType.schemaType schema`

Maps one **normalized** schema to a `lib.types` value:

| Schema | Type |
| --- | --- |
| `x-kubernetes-int-or-string` | `either int str` |
| `x-kubernetes-embedded-resource` or `x-kubernetes-preserve-unknown-fields` without `properties` | `attrsOf anything` for objects, else `anything` |
| `enum` | `enum` of its values |
| `oneOf`/`anyOf` | `oneOf` of the branch types |
| `type = "string"` | `str` |
| `type = "integer"` | `int` |
| `type = "number"` | `number` |
| `type = "boolean"` | `bool` |
| `type = "array"` | `listOf (schemaType items)` (`listOf anything` without `items`) |
| object with `properties` | `submodule` with one option per property; required properties have no default, others are `nullOr t` defaulting to `null`; `description` carried over; `x-kubernetes-preserve-unknown-fields` adds `freeformType = attrsOf anything` |
| object with schema `additionalProperties` | `attrsOf (schemaType additionalProperties)` |
| other object / no type | `attrsOf anything` for objects, `anything` without `type` |

Property names are used verbatim as option names.

### `lib/resourceModule.nix` → `resourceModule.mkResourceModule resources`

Takes a list of resource schema records, returns a module declaring
`options.resources = mkOption { type = submodule { options.<group|core>.<version>.<Kind> = mkOption { type = attrsOf (submodule ...); default = { }; }; }; }`.
Each instance type is the kind's normalized schema with `apiVersion`, `kind`,
and `metadata.name` removed (and `metadata.namespace` too for cluster-scoped
kinds) — `render` injects those. `resourceModule.instanceType resource` is
exposed for testing.

### `lib/kubernetes.nix` → `kubernetes.loadKubernetes { openapi, discovery ? null }`

`openapi`: list of parsed OpenAPI v3 documents; `discovery`: parsed
`aggregated_v2.json` or `null`. Returns resource schema records for every
schema with `x-kubernetes-group-version-kind`, skipping `*List` kinds and
kinds whose scope can't be determined. Scope comes from discovery for named
groups when available, otherwise from `paths` (`/api/<v>/<plural>` or
`/apis/<g>/<v>/<plural>` → cluster, `.../namespaces/{namespace}/<plural>` →
namespaced, matched on the operation's `x-kubernetes-group-version-kind`).
`definitions` is the document's `components.schemas`. Duplicate
group/version/kind throws; no resources throws.

### `lib/crd.nix` → `crd.loadCrds documents`

`documents`: list of parsed YAML documents. `List`/`CustomResourceDefinitionList`
documents are flattened, non-CRD documents skipped. Validates
`apiVersion = "apiextensions.k8s.io/v1"`, non-empty `spec.group`,
`spec.names.kind`, `spec.scope` (`Namespaced`/`Cluster`), `spec.versions`; one
record per served version with `schema = versions[].schema.openAPIV3Schema`
and `definitions = { }`. Throws on invalid shape, duplicate resources, or no
CRDs at all.

### `lib/yaml2json.nix` → `yaml2json pkgs yamlFile`

Returns the list of documents in a (multi-document) YAML file, via `yq` in a
`runCommand` read back with `builtins.fromJSON` (import-from-derivation).
Empty documents are dropped.

### `lib/render.nix`

- `stripNulls value` — recursively drops `null` attribute values (inside lists too).
- `apiVersion { group, version }` — `version` for `""`/`core`, else `group/version`.
- `toManifest { apiVersion, kind, name, body }` — `body` with `apiVersion`,
  `kind`, `metadata.name` injected, nulls and `_module` attrs stripped.
- `manifestsFromResources resources` — flattens
  `resources.<group>.<version>.<Kind>.<name>` into a list of manifests (sorted
  by group, version, kind, name).
- `toYaml pkgs manifests` — derivation of a multi-document YAML file (`---`
  separated), via `pkgs.formats.yaml`.

### `lib/mkKubernetesModule.nix` → `mkKubernetesModule { kubernetesSrc }`

Reads `api/openapi-spec/v3/*.json` (documents with `components`) and
`api/discovery/aggregated_v2.json` from `kubernetesSrc` and returns
`resourceModule.mkResourceModule (kubernetes.loadKubernetes { ... })`. No
derivations — the source is already in the store.

### `lib/importCrdModule.nix` → `importCrdModule { pkgs, crdFile }`

`yaml2json` → `crd.loadCrds` → `resourceModule.mkResourceModule`.

### `modules/resources.nix`

`options.validation.strict` (`mkEnableOption`, default `false`) and
`options.resources` as a submodule whose `freeformType` is `null` when strict,
else `attrsOf (attrsOf (attrsOf (attrsOf (attrsOf anything))))` — so unknown
groups/kinds are accepted unless strict. Merges with the submodule
declarations from `resourceModule`.

### `modules/build.nix`

`options.build.manifests` (read-only list) and `options.build.yaml`
(read-only package) — thin wiring over `lib/render.nix`
(`manifestsFromResources config.resources`, `toYaml pkgs ...`).

## TDD workflow

0. Integration/e2e tests first (`tests/integration`, `tests/e2e`).
1. Per unit, bottom-up: write `tests/unit/<unit>.nix` (red), implement (green),
   commit, re-run integration/e2e.
2. Repeat until every check is green, then write `examples/` (illustrative only).

Fast loop: `nix develop -c nix-unit --flake .#tests.unit.<unit>`.
