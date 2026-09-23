# catenix design

Kubernetes manifests written as Nix, type-checked against the Kubernetes API
(and CRDs) by the module system. The Kubernetes OpenAPI v3 spec and CRD
`openAPIV3Schema` documents are parsed with `builtins.fromJSON` and walked by
pure Nix functions that build real `lib.types.*` values — the type *is* the
value; no generated source text.

Guiding rules: prefer native Nix/flake mechanisms; add a dependency only when
nothing native covers the need; one unit of responsibility per file; avoid
non-Nix code; strict TDD (see below).

## Usage

Resources are declared in ordinary modules as
`resources.<group|core>.<version>.<Kind>.<name>`, composed with
`nixosModules.default` in a `lib.evalModules` call that provides `pkgs`.
`config.build.yaml` is the rendered multi-document YAML file,
`config.build.manifests` the same manifests as Nix values. See `examples/`.

From another flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    catenix.url = "github:charlie-horse/catenix";
    catenix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, catenix, ... }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      app = nixpkgs.lib.evalModules {
        modules = [
          catenix.nixosModules.default
          ./app.nix
        ];
        specialArgs = {
          inherit pkgs;
          catenix = catenix.lib;
        };
      };
    in
    {
      # nix build .#manifests && kubectl apply -f result
      packages.x86_64-linux.manifests = app.config.build.yaml;
    };
}
```

`pkgs` can also be set with `{ _module.args.pkgs = pkgs; }` in `modules`, but
`_module.args` can't be used in `imports`, so a module that imports a CRD
(`imports = [ (catenix.importCrdModule { inherit pkgs; crdFile = ./crd.yaml; }) ]`)
needs `pkgs` and `catenix` in `specialArgs`. With `_module.args`, pass the CRD
module in `modules` directly instead.

Without a flake of your own, the `render` app evaluates a module file the same
way (`pkgs` and `catenix` in `specialArgs`) and prints the YAML; type errors
exit non-zero:

```sh
nix run github:charlie-horse/catenix#render -- ./app.nix | kubectl apply -f -
```

## Flake outputs

| Output | Contents |
| --- | --- |
| `lib` | Every `lib/*.nix` unit, keyed by file name (`lib/default.nix`). System-agnostic: units that build derivations take `pkgs` as an argument. |
| `nixosModules.default` | `modules/resources.nix` + `modules/build.nix` + core Kubernetes types from the pinned `kubernetes-src`. Callers run their own `lib.evalModules` and must provide `pkgs` as a module argument (`specialArgs` or `_module.args.pkgs`); see [Usage](#usage). |
| `tests` | Every suite as nix-unit `{ expr, expected }` cases (`tests/default.nix`). Run one with `nix-unit --flake .#tests.unit.normalize`. |
| `checks.<system>` | One named check per suite (`tests/checks.nix`). |
| `apps.<system>.render` | `nix run .#render -- <path-to-module.nix>` evaluates that module file with `nixosModules.default` (`pkgs` and `catenix` in `specialArgs`) and prints its `config.build.yaml` (`apps/render.nix`, `apps/renderModule.nix`). |
| `devShells.<system>.default` | `nix-unit`, `yq-go`, `nixfmt`, `jq`. |
| `formatter.<system>` | `nixfmt`. |

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
| `oneOf`/`anyOf` without `type` | `oneOf` of the branch types (with a `type`, `oneOf`/`anyOf` are CRD "exactly one of" constraints and are ignored) |
| `type = "string"` | `str` |
| `type = "integer"` | `int` |
| `type = "number"` | `number` |
| `type = "boolean"` | `bool` |
| `type = "array"` | `listOf (schemaType items)` (`listOf anything` without `items`) |
| object with `properties` | `submodule` with one option per property; required properties have no default, others are `nullOr t` defaulting to `null`; `description` carried over; `x-kubernetes-preserve-unknown-fields` adds `freeformType = attrsOf anything` |
| object with schema `additionalProperties` | `attrsOf (schemaType additionalProperties)` |
| other object / no type | `attrsOf anything` for objects, `anything` without `type` |

Property names are used verbatim as option names. Unset optional properties
come back as `null` (not absent), which `render` strips. In the real spec
`IntOrString` is a typeless `oneOf [integer string]` and `Quantity` a typeless
`oneOf [string number]`, both covered by the `oneOf` row.

### `lib/resourceModule.nix` → `resourceModule.mkResourceModule resources`

Takes a list of resource schema records, returns a module declaring
`options.resources = mkOption { type = submodule { options.<group|core>.<version>.<Kind> = mkOption { type = attrsOf (submodule ...); default = { }; }; }; }`.
Each instance type is the kind's normalized schema with `apiVersion`, `kind`,
and `metadata.name` removed (and `metadata.namespace` too for cluster-scoped
kinds) — `render` injects those — and from the matching `required` lists.
Where an object accepts unknown fields (a bare `type: object` CRD `metadata`,
`x-kubernetes-preserve-unknown-fields`, no properties), removal alone would
let users set them, so there each is declared as an optional empty `enum`,
which rejects any value. Every kind gets a `metadata` property, freeform if its
schema doesn't declare one. The kind's `description` goes on the `<Kind>`
option. `resourceModule.instanceType resource` is exposed for testing.

Laziness is shallow: building the module reads every kind's top-level schema
(the module system inspects each kind option's type), while nested schemas and
`definitions` stay unforced — the real spec plus one declared ConfigMap
evaluates in about 1.5 s. Declaring the same kind from two modules fails with
the module system's "already declared" error.

### `lib/kubernetes.nix` → `kubernetes.loadKubernetes { openapi, discovery ? null }`

`openapi`: list of parsed OpenAPI v3 documents; `discovery`: parsed
`aggregated_v2.json` or `null`. Returns resource schema records for every
schema with `x-kubernetes-group-version-kind`, skipping `*List` kinds and
kinds whose scope can't be determined. Scope comes from discovery for named
groups when available, otherwise from `paths` (`/api/<v>/<plural>` or
`/apis/<g>/<v>/<plural>` → cluster, `.../namespaces/{namespace}/<plural>` →
namespaced, matched on the operation's `x-kubernetes-group-version-kind`; a
namespaced path wins, since namespaced kinds are also listed at their
all-namespaces path). Discovery is consulted per kind: a named-group kind
missing from it falls back to `paths`, and core-group entries are ignored.
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
Empty documents are dropped. The builder never fails: yq's error text becomes
the output and is rethrown as a Nix `throw`, because a failed
import-from-derivation build can't be caught by `builtins.tryEval`.

### `lib/render.nix`

- `stripNulls value` — recursively drops `null` attribute values (inside lists too).
- `apiVersion { group, version }` — `version` for `""`/`core`, else `group/version`.
- `toManifest { apiVersion, kind, name, body }` — `body` with `apiVersion`,
  `kind`, `metadata.name` injected, nulls and `_module` attrs stripped.
- `manifestsFromResources resources` — flattens
  `resources.<group>.<version>.<Kind>.<name>` into a list of manifests (sorted
  by group, version, kind, name).
- `toYaml pkgs manifests` — derivation of a multi-document YAML file (`---`
  separated). Each manifest goes through `pkgs.formats.yaml { }` (YAML 1.1,
  so strings like `on`/`yes` get quoted, which Kubernetes' YAML 1.1 parser
  needs); one `runCommand` drops each file's `%YAML`/`---` header and joins
  them, since the generator writes one document per file. Lists are indented
  level with their key.

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
declarations from `resourceModule`. For that merge to work, every other
declaration of `options.resources` (each `resourceModule`) sets only `type`, as
a plain `types.submodule` with no `freeformType`, whose group and version
levels are nested option sets and whose first real option is the kind — this
module owns `default`, `description`, and the freeform type.

### `modules/build.nix`

`options.build.manifests` (read-only list) and `options.build.yaml`
(read-only package) — thin wiring over `lib/render.nix`
(`manifestsFromResources config.resources`, `toYaml pkgs ...`).

### `apps/render.nix`, `apps/renderModule.nix`

`renderModule.nix` is the evaluation, a file for
`nix build --impure --file apps/renderModule.nix --argstr module <absolute path> [--argstr system <system>]`:
it loads this flake with `builtins.getFlake` on its own source directory and
returns `config.build.yaml` of the module composed with `nixosModules.default`,
with `pkgs` (`nixpkgs.legacyPackages.<system>`) and `catenix` (the flake's
`lib`) in `specialArgs`. `--impure` because the module lives outside the store.
`render.nix` is the app: a `writeShellApplication` that makes its one argument
absolute with `realpath` (so paths are relative to the caller's working
directory), runs that `nix build` with the caller's `nix` from `PATH`, and
prints the built file. Not covered by checks, since it runs `nix` itself; try
it on `examples/`.

## TDD workflow

0. Integration/e2e tests first (`tests/integration`, `tests/e2e`).
1. Per unit, bottom-up: write `tests/unit/<unit>.nix` (red), implement (green),
   commit, re-run integration/e2e.
2. Repeat until every check is green, then write `examples/` (illustrative only).

Fast loop: `nix develop -c nix-unit --flake .#tests.unit.<unit>`.

## Known limitations

A manual smoke test applied rendered output to a real k3s v1.37 cluster (not
part of the repo). Everything that type-checked was accepted, apart from the
gaps below — catenix checks types, not every rule the API server enforces:

- **No enums for built-in kinds.** The checked-in OpenAPI v3 spec carries no
  `enum` constraints (the live server publishes them), so fields like
  `imagePullPolicy`, `Service.type`, `restartPolicy` or `pathType` accept any
  string. CRD enums are enforced.
- **String formats and patterns aren't checked**: base64 (`Secret.data`),
  quantities (`cpu = "lots"`), names, label syntax, `pattern`, `maxLength`.
- **Validation outside the schema** (selector/template label agreement, port
  ranges, duplicate list-map keys, named-port rules) is the server's job.
- **CRD `metadata` is untyped** when the CRD declares none (the usual case):
  `metadata.labels.tier = 5` type-checks but doesn't decode on the server.
- **All versions in the spec are typed**, including alpha/beta group-versions
  the server doesn't serve by default, and fields behind disabled feature gates
  (silently dropped by the server).
- **Server-set fields aren't blocked**: `status`, `metadata.uid`,
  `resourceVersion`, `managedFields`, `creationTimestamp` are accepted and then
  ignored or rejected by the server.
- **Unknown kinds type-check unless `validation.strict = true`**, so a kind
  typo (`Deploymnet`) only fails at apply time in the default mode.
