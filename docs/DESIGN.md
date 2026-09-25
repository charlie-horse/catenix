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
| `nixosModules.default` | `modules/resources.nix` + `modules/build.nix` + core Kubernetes types from the pinned `kubernetes-src`, for the group/versions a default cluster serves (`apis = "default"`; `mkKubernetesModule` below shows how to add more). Callers run their own `lib.evalModules` and must provide `pkgs` as a module argument (`specialArgs` or `_module.args.pkgs`); see [Usage](#usage). |
| `tests.systems.<system>` | The sandbox-safe suites as nix-unit `{ expr, expected }` cases, set by nix-unit's flake-parts module from `perSystem.nix-unit.tests` (`tests/flake-module.nix`). Run one with `nix-unit --flake .#tests.systems.x86_64-linux.unit.normalize`. |
| `legacyPackages.<system>.evalTimeTests` | The suites that build derivations during evaluation (`unit.yaml2json`, `unit.toYaml`, `unit.importCrdModule`, `integration.*`, `e2e.*`). Run one with `nix-unit --flake .#legacyPackages.x86_64-linux.evalTimeTests.e2e.realSpec`. |
| `checks.<system>` | `nix-unit` (every sandbox-safe suite, from nix-unit's module) plus one named check per eval-time suite (`unit-yaml2json`, …, `e2e-real-crd`). |
| `apps.<system>.render` | `nix run .#render -- <path-to-module.nix>` evaluates that module file with `nixosModules.default` (`pkgs` and `catenix` in `specialArgs`) and prints its `config.build.yaml` (`apps/render.nix`, `apps/renderModule.nix`). |
| `devShells.<system>.default` | `nix-unit`, `yq-go`, `nixfmt`, `jq`, `kubernetes-helm`. |
| `formatter.<system>` | `nixfmt`. |

## Dependency policy

Flake inputs: `nixpkgs`, `kubernetes-src`, `flake-parts` and `nix-unit`.
Everything else is a `builtins` primop or comes from nixpkgs.

- **flake-parts** — the flake is a `flake-parts.lib.mkFlake` module
  (`systems`, `perSystem`, `flake`), and it's how nix-unit's own flake module
  plugs in. `nixpkgs-lib` follows `nixpkgs`.
- **nix-unit** — test runner. The flake input provides its flake-parts module
  (`nix-unit.modules.flake.default`); the binary comes from nixpkgs
  (`nix-unit.package = pkgs.nix-unit`) so it isn't built from source.
  `nixpkgs` follows ours, and its dev-only inputs (`treefmt-nix`,
  `nix-github-actions`) follow `""` so they're never fetched.
- **yq-go** (nixpkgs) — Nix has no YAML parser or encoder: CRDs ship as YAML,
  and manifests are rendered to it. Scoped to `lib/yaml2json.nix` and
  `render.toYaml`. (`pkgs.formats.yaml` isn't used: its encoder, remarshal
  with PyYAML, leaves strings like `08` and `0o17` unquoted, which Kubernetes'
  Go-based parser reads as numbers.)
- **kubernetes-helm** (nixpkgs) — Helm charts are Go templates plus Helm's
  own functions (Sprig, `include`, `tpl`, `lookup`, `.Capabilities`, ...);
  re-implementing that in Nix would be a large, never-quite-equal copy, so the
  official `helm` CLI renders them. Scoped to `lib/helmTemplate.nix`
  (`helm template`) and `lib/fetchChart.nix` (`helm pull`).

`kubernetes-src` is a `git+https://github.com/...?ref=refs/tags/<tag>&shallow=1`
input rather than `github:`: Kubernetes marks `hack/lib/version.sh` as
`export-subst`, so GitHub's tarball differs from the git tree, and the git
fetcher is the one that works everywhere (including sandboxed CI with only git
egress). Bump it by editing the tag and running `nix flake update kubernetes-src`.

## Checks: two runners, one test format

Pure suites go to `perSystem.nix-unit.tests`; nix-unit's flake-parts module
runs them in the sandboxed `checks.<system>.nix-unit`, with the flake inputs
passed in through `nix-unit.inputs`. Suites that read a derivation's output
back during evaluation (YAML→JSON, YAML encoding, CRD import, anything
asserting rendered YAML) can't build inside that sandbox, so
`tests/flake-module.nix` evaluates them during `nix flake check` itself with
`lib.debug.runTests`, one named check per suite. Both runners read the same `{ expr, expected }` cases.
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
| `x-kubernetes-int-or-string` | `either int str`, the string side checked as a `string` schema's below |
| `x-kubernetes-embedded-resource` or `x-kubernetes-preserve-unknown-fields` without `properties` | `attrsOf anything` for objects, else `anything` |
| `enum` | `enum` of its values |
| `oneOf`/`anyOf` without `type` | `oneOf` of the branch types (with a `type`, `oneOf`/`anyOf` are CRD "exactly one of" constraints and are ignored) |
| `type = "string"` | `str` |
| `minLength`/`maxLength`, `format`, `pattern` on a string | `str` with an `addCheck` for each (in that order), and a `description` naming them: lengths in characters (Unicode code points, as Kubernetes counts them, via `utf8.length`), a `format` from `stringFormat` (others ignored), a `pattern` `lib/pattern.nix` translates (else unchecked, and the description says so) |
| `type = "integer"` | `int`; `ints.s32` with `format = "int32"` (Kubernetes decodes those into Go `int32`s, which reject or silently wrap larger values; an `int64` is what a Nix int already is) |
| `type = "number"` | `number` |
| `minimum`/`maximum` on `integer`/`number` | the type above with an `addCheck` for the bounds, and a `description` naming them |
| `type = "boolean"` | `bool` |
| `type = "array"` | `listOf (schemaType items)` (`listOf anything` without `items`) |
| `minItems`/`maxItems`, `uniqueItems` on an array | the list type with the counts (or no duplicates) checked on the **merged** list, since lists concatenate across definitions |
| object with `properties` | `submodule` with one option per property; required properties have no default, others are `nullOr t` defaulting to `null`; `description` carried over; `x-kubernetes-preserve-unknown-fields` adds `freeformType = attrsOf anything` |
| object with schema `additionalProperties` | `attrsOf (schemaType additionalProperties)` |
| other object / no type | `attrsOf anything` for objects, `anything` without `type` |
| `minProperties`/`maxProperties` on any object type above | that type with the count of non-null attributes (`render` drops nulls) checked on the merged value |

Property names are used verbatim as option names. Unset optional properties
come back as `null` (not absent), which `render` strips. In the real spec
`IntOrString` is a typeless `oneOf [integer string]` and `Quantity` a typeless
`oneOf [string number]`, both covered by the `oneOf` row.

Bounds are made exclusive by OpenAPI v3.0's (and so CRDs') boolean
`exclusiveMinimum`/`exclusiveMaximum`, or given as numbers in those keys (JSON
Schema 2019-09, OpenAPI 3.1); the tightest of several wins, and `int32` limits
combine with them. Module errors quote the description, e.g. ``is not of type
`null or integer between 1 and 10 (both inclusive)'``; exclusive integer
bounds are described as the inclusive ones they equal (`exclusiveMinimum: 0`
reads "at least 1"), number bounds as e.g. "greater than 0 and at most 1".
Format and bounds only shape plain
`integer`/`number` schemas: an `enum` still admits exactly its values,
`x-kubernetes-int-or-string` stays `either int str` (its string side takes the
string constraints: CRDs put quantity-style `pattern`s there), and each branch of a
typeless `oneOf` keeps its own. Not checked: the int32 range of the real spec's
`IntOrString`, whose `integer` branch declares no `format`.

String, list and object constraints read like the numeric ones:
``string between 1 and 63 characters long, in k8s-short-name format, matching
the pattern `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` ``, `list of string with at most
2 items, without duplicates`, `attribute set of string with at least 1
property`, and an untranslatable pattern as ``string (pattern `(?i)^a$` not
checked)``. Strings are checked per definition (`addCheck`; a string can't be
merged from parts); lists and objects on the merged value, by wrapping the
module system's v2 merge (a failure reads ``... is not of type `list of string
with at most 1 item'. TypeError: The merged value has 2 items.``) and
`substSubModules`, which the module system uses to rebuild types holding
submodules. Building a type reads none of the constraint values; checking a
value does. Lengths are only counted in code points when the byte length
doesn't already decide them.

### `lib/utf8.nix`

Nix strings are bytes; Kubernetes counts characters. `utf8.length s` is the
number of code points (bytes less continuation bytes, which `replaceStrings`
removes — no regex, so any length works), `utf8.isAscii s` whether there are
no multibyte characters. `continuationMin`/`continuationMax` (80, BF) and
`leadMin`/`leadMax` (C2, F4) are one-byte strings cut out of multibyte
characters with `substring` (Nix has no byte escapes), for regex brackets;
`continuationBytes` lists all 64.

### `lib/pattern.nix` → `pattern.translate p`, `pattern.matcher p`

Kubernetes checks `pattern` with Go's `regexp` (RE2 syntax, Perl flags;
ECMA-262 in name only), searching anywhere in the value. `builtins.match` is
libstdc++'s POSIX ERE and matches the whole string. `translate p` parses the
RE2 pattern and re-emits it as an ERE with the same set of matching strings,
or returns null:

- Wrapped as `.*(p).*`, dropping the `.*` on a side every top-level branch
  anchors (`^`/`\A`, `$`/`\z`). Anchors stay anchors anywhere; `$` is
  end-of-text, as in RE2 without `(?m)`.
- `\d \D \w \W \s \S` (RE2's ASCII sets; `\s` has no `\v`), inside brackets
  too; POSIX `[:name:]` and `[:^name:]`; `\xHH`, `\x{H}`, `\a \f \t \n \r \v`,
  escaped punctuation; `(?:...)` and named groups `(?P<n>...)`/`(?<n>...)` as
  plain groups; lazy quantifiers as greedy ones (a match exists either way);
  `{n}`, `{n,}`, `{n,m}` (anything else is a literal `{`, as in RE2).
- Brackets become sets of ASCII codes, re-emitted in POSIX order (`]` first,
  `^` not first, `-` last; `\` is literal there).
- RE2 matches characters, the ERE bytes: `.`, negated classes and other
  classes admitting non-ASCII characters get a second branch matching one
  whole multibyte character (a lead byte and its continuations), so `^.{3}$`
  counts characters.
- Refused (null): flags `(?i)` etc., `\b \B`, `\p`/`\P` classes, `\Q..\E`,
  `\C`, octal/backreference digits, lookarounds, non-ASCII pattern text,
  anything RE2 itself rejects (unbalanced groups, bad ranges, nested
  quantifiers, counts over 1000), and patterns whose counted repetitions
  would expand past about 10000 atoms (libstdc++ copies them into its
  automaton and aborts evaluation past its size limit).

An invalid ERE aborts evaluation instead of throwing, so a translation is
either valid or null. `matcher p` is `null` for a refused pattern, else a
predicate; values over `inputLimit` (8192) bytes are accepted unchecked,
because libstdc++'s backtracking matcher recurses per character and
overflows the stack on inputs of a few tens of kilobytes. Every distinct
`pattern` in the CRDs vendored in the pinned `kubernetes-src` (17) translates;
of 24 common CRD patterns in `tests/unit/pattern.nix` 19 do, the other five
being exactly the refused features.

### `lib/stringFormat.nix` → `stringFormat.check format`

A predicate for a string `format`, or null if it isn't checked. Names
normalize like kube-openapi's (dashes dropped: `date-time` = `datetime`).
The apiextensions-apiserver strips formats outside a fixed list
(`pkg/apiserver/validation/formats.go`) and validates the rest with
kube-openapi's `strfmt`; each predicate mirrors that Go code:

- checked: `bsonobjectid`, `byte`, `date`, `datetime`, `duration`,
  `hostname`, `mac`, `uuid`, `uuid3`, `uuid4`, `uuid5`, `isbn`, `isbn10`,
  `isbn13`, `creditcard`, `ssn`, `hexcolor`, `rgbcolor`, `k8s-short-name`,
  `k8s-long-name`;
- not checked: `password` (anything goes), and `uri`, `email`, `ipv4`,
  `ipv6`, `cidr`, which need Go's `net/url`, `net/mail` and `net` parsers.

Deliberate leniencies (never a false rejection): `byte` also admits the empty
string and line breaks, which Go's `encoding/json` accepts for the `[]byte`
fields of built-in kinds (`Secret.data`); `hostname` doesn't check non-ASCII
names (its `\p{L}`/`\p{S}` classes are reduced to their ASCII members);
`duration` ignores `time.ParseDuration`'s overflow beyond 12-digit numbers
of Greek-mu microseconds. Regex-based checks with no length bound in Go
(`datetime`, `duration`, `isbn*`, `creditcard`, `rgbcolor`) accept values over
8192 bytes unchecked; `byte` uses `replaceStrings`, so works at any length.

### `lib/resourceModule.nix` → `resourceModule.mkResourceModule resources`

Takes a list of resource schema records, returns a module declaring
`options.resources = mkOption { type = submodule { options.<group|core>.<version>.<Kind> = mkOption { type = attrsOf (submodule ...); default = { }; }; }; }`.
Each instance type is the kind's normalized schema with the fields users
can't set removed, from `properties` and from the matching `required` lists:
`apiVersion`, `kind`, and `metadata.name` (and `metadata.namespace` too for
cluster-scoped kinds), which `render` injects; and the server-set fields
`status` and `metadata.{uid, resourceVersion, generation, creationTimestamp,
deletionTimestamp, deletionGracePeriodSeconds, managedFields, selfLink}`,
which the API server ignores, overwrites or rejects on create/apply. Where an
object accepts unknown fields (a bare `type: object` CRD `metadata`,
`x-kubernetes-preserve-unknown-fields`, no properties), removal alone would
let users set them, so there each is declared as an optional empty `enum`,
which rejects any value. Ordinary metadata (`labels`, `annotations`,
`finalizers`, `ownerReferences`, ...) is untouched. Every kind gets a `metadata` property, freeform if its
schema doesn't declare one. The kind's `description` goes on the `<Kind>`
option. `resourceModule.instanceType resource` is exposed for testing.

The module also declares `options.kinds` the same way: a submodule with a
read-only `kinds.<group|core>.<version>.<Kind>.namespaced` bool per kind,
defaulting to the record's scope. It is how code outside the schema (e.g.
`manifestsToResources`, filling in namespaces as `kubectl apply -n` does)
learns a declared kind's scope from the evaluated configuration.

Laziness is shallow: building the module reads every kind's top-level schema
(the module system inspects each kind option's type), while nested schemas and
`definitions` stay unforced — the real spec plus one declared ConfigMap
evaluates in about 1.5 s. Declaring the same kind from two modules fails with
the module system's "already declared" error.

### `lib/kubernetes.nix` → `kubernetes.loadKubernetes { openapi, discovery ? null, apis ? "default" }`

`openapi`: list of parsed OpenAPI v3 documents; `discovery`: parsed
`aggregated_v2.json` or `null`. Returns resource schema records for every
schema with `x-kubernetes-group-version-kind`, skipping `*List` kinds and
kinds whose scope can't be determined, and kinds whose group/version `apis`
leaves out:

- `"default"` — only GA versions (`v<N>`: `v1`, `v2`), the ones a default
  kube-apiserver serves. Alpha and beta versions (`v1beta1`, `v1alpha3`) are
  left out.
- `"all"` — every version in the spec.
- a non-empty list of `"<group>/<version>"` strings (`"v1"` for core) — exactly
  those; one without any kind in the spec throws, catching typos.

Any other value throws. Nothing in the spec or discovery files marks what is
served by default (the checked-in discovery lists every version as
`freshness: Current`, and the spec has a document per version), so
`"default"` goes by version name: new beta APIs have been disabled by default
since Kubernetes 1.24, and the pinned v1.37's
`pkg/controlplane/instance.go` lists every alpha and beta group/version in the
spec as disabled by default. That list is Go code, so it's used to check the
rule, not read. A smoke test's default k3s v1.37 server served exactly the 23
built-in group/versions the rule keeps (`tests/unit/mkKubernetesModule.nix`). Scope comes from discovery for named
groups when available, otherwise from `paths` (`/api/<v>/<plural>` or
`/apis/<g>/<v>/<plural>` → cluster, `.../namespaces/{namespace}/<plural>` →
namespaced, matched on the operation's `x-kubernetes-group-version-kind`; a
namespaced path wins, since namespaced kinds are also listed at their
all-namespaces path). Discovery is consulted per kind: a named-group kind
missing from it falls back to `paths`, and core-group entries are ignored.
`definitions` is the document's `components.schemas`. Duplicate
group/version/kind throws; no resources (after `apis`) throws.

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
  `kind`, `metadata.name` injected and nulls stripped. Everything else is
  kept, `_module` keys included: `evalModules` already leaves `_module` out of
  submodule configs, so one in `body` is user data (e.g. a ConfigMap key).
- `manifestsFromResources resources` — flattens
  `resources.<group>.<version>.<Kind>.<name>` into a list of manifests in apply
  order: core `Namespace`s first, then `apiextensions.k8s.io`
  `CustomResourceDefinition`s, then everything else, each part sorted by group,
  version, kind, name. `kubectl apply -f` creates objects in file order, so a
  fresh apply finds namespaces and CRDs before the objects that need them.
- `toYaml pkgs manifests` — derivation of a multi-document YAML file, one
  `---`-separated document per manifest (empty for none). A `runCommand` runs
  one `yq` over `builtins.toJSON manifests`, read as YAML: JSON is YAML, and
  unlike yq's JSON reader (which turns numbers into floats) that keeps number
  literals exact. NEL, LS and PS are escaped first, since JSON allows them raw
  in strings and YAML reads them as line breaks. yq resets every node's style
  (block YAML) except on strings YAML 1.1 reads as booleans (`yes`, `on`, ...)
  or base 60 numbers (`12:30`), which keep JSON's double quotes, and its
  encoder quotes every other string that would read back as something else
  (`08`, `0o17`, `true`, `<<`, ...): Kubernetes' parser (`sigs.k8s.io/yaml`,
  goyaml.v2) reads YAML 1.1 booleans and Go's number syntax, and go-yaml's own
  encoder also quotes base 60. Multi-line strings become literal blocks (`|`,
  `|-`, `|+`), or double-quoted when a line has trailing spaces or a CR. Keys
  keep Nix's sorted order, lists are indented level with their key (`-c`),
  long lines aren't folded. The quoting was checked against
  `sigs.k8s.io/yaml` on an adversarial corpus; `tests/unit/toYaml.nix` keeps
  the cases.

### `lib/mkKubernetesModule.nix` → `mkKubernetesModule { kubernetesSrc, apis ? "default" }`

Reads `api/openapi-spec/v3/*.json` (documents with `components`) and
`api/discovery/aggregated_v2.json` from `kubernetesSrc` and returns
`resourceModule.mkResourceModule (kubernetes.loadKubernetes { ..., apis })`.
No derivations — the source is already in the store.

To type group/versions a cluster enables beyond the defaults (e.g. with
`--runtime-config`), add a second module listing just those next to
`nixosModules.default`; the kinds differ by version, so the declarations
merge:

```nix
imports = [
  (catenix.lib.mkKubernetesModule {
    kubernetesSrc = catenix.inputs.kubernetes-src;
    apis = [ "coordination.k8s.io/v1beta1" ];
  })
];
```

### `lib/importCrdModule.nix` → `importCrdModule { pkgs, crdFile }`

`yaml2json` → `crd.loadCrds` → `resourceModule.mkResourceModule`.

### `lib/helmTemplate.nix` → `helmTemplate pkgs { chart, release, values ? { }, kubeVersion ? null, apiVersions ? [ ], includeCrds ? true, extraArgs ? [ ] }`

A `runCommand` derivation (`helm-template-<release>.json`) whose output is
one JSON array of the manifests `helm template` renders:

- `chart`: a chart directory or `.tgz` — a path (copied to the store), a
  store path, or a derivation such as `fetchChart`'s or a `flake = false`
  input. The build has no network, so declared dependencies must already be
  under the chart's `charts/` (published archives include them; for a source
  checkout run `helm dependency build` first). Helm refuses a chart missing one
  (`found in Chart.yaml, but missing in charts/ directory: <name>`), and the
  build fails with that message plus a hint.
- `release`: `{ name; namespace ? "default"; }` → the release name and
  `--namespace` (`.Release.Namespace`).
- `values`: `builtins.toJSON` (JSON is YAML) through `passAsFile`, passed with
  `--values` over the chart's `values.yaml`, subcharts' values nested under
  their names as usual.
- `kubeVersion` → `--kube-version`, `apiVersions` → one `--api-versions`
  each (`.Capabilities`); Helm's built-in defaults otherwise (Helm 4.3:
  Kubernetes v1.37.0).
- `includeCrds` → `--include-crds` (the chart's `crds/` directory); CRDs in
  `templates/` are rendered either way.
- `extraArgs` go last, verbatim (e.g. `--skip-tests`, `--no-hooks`,
  `--show-only`).

`HOME` and `HELM_{CACHE,CONFIG,DATA}_HOME` point into the build directory. The
builder is one pipeline, `helm template ... | yq ... > $out`: Helm splits and
cleans the documents by its own rules and prints them `---`-separated; yq
(`eval-all`) collects the stream into one array, dropping empty
(comment-only) documents, so no second conversion is needed. yq parses YAML
1.2, while Kubernetes and Helm's install path (`sigs.k8s.io/yaml`, a
go-yaml v2 fork) read YAML 1.1; yq is told the plain-scalar values where
they differ: integers with a bare leading zero are octal (`defaultMode: 0644`
is 420, as in bitnami's redis chart), and `y`/`yes`/`on`/`n`/`no`/`off` (three
casings each) are booleans. Quoted scalars and map keys are unchanged. Unlike
`yaml2json`, a failure fails the build (`helm`'s error on stderr) rather than
becoming a catchable `throw`: the output is meant to be built directly too,
and a "successful" build holding an error message would be a trap. Tests
check failures with `pkgs.testers.testBuildFailure`.

### `lib/fetchChart.nix` → `fetchChart pkgs { repo, name, version, hash }`

A fixed-output derivation (`helm-chart-<name>-<version>`, recursive NAR
hash) running `helm pull --untar`; the output is the unpacked chart
directory, subcharts included as published. `repo` is a classic repository
URL (`https://...`, pulled with `--repo`) or an OCI registry
(`oci://...`, pulling `<repo>/<name>`); anything else throws. Build once with
`lib.fakeHash` and copy the reported hash. Like nixpkgs' fetchers it takes
the proxy variables and `NIX_SSL_CERT_FILE` (`impureEnvVars`), falling back
to `cacert` for TLS. Only the derivation is unit-tested (fetching needs the
network); by hand, cert-manager v1.21.2 from `https://charts.jetstack.io`
and from `oci://quay.io/jetstack/charts` both gave
`sha256-AsbUc4Q9aVfTmENGPPmjOwC6V6v3MpTN1cKIl8csi10=` — the same NAR hash
as the unpacked `.tgz`, so a chart can move between `fetchChart` and a flake
input without changing its hash.

A classic repository's archive can instead be a flake input, which Nix
fetches, unpacks and locks itself:

```nix
inputs.cert-manager-chart = {
  url = "tarball+https://charts.jetstack.io/charts/cert-manager-v1.21.2.tgz";
  flake = false;
};
```

### `lib/manifestsToResources.nix` → `manifestsToResources { manifests, namespace ? null, noHooks ? false, skipTests ? false }`

Pure. Turns a list of plain manifests (what `helm template` renders) into a
module defining `resources`, so they are type-checked like any other resource
when `build.manifests` is evaluated:

- `v1` `List` documents are flattened into their items; `null`s are dropped
  first (Kubernetes reads them as absent).
- Each manifest becomes `resources.<group|core>.<version>.<Kind>.<name>`.
  Stripped: `apiVersion`, `kind`, `metadata.name` (the key; `render` injects
  them back) and the server-set fields catenix rejects, `status` and
  `metadata.{uid, resourceVersion, generation, creationTimestamp,
  deletionTimestamp, deletionGracePeriodSeconds, managedFields, selfLink}`.
  (The charts surveyed — ingress-nginx, cert-manager, bitnami redis/postgresql,
  kube-prometheus-stack, grafana — emit none of them at the top level; their
  `status: {}` lines are CRD `subresources`, which are kept. Templates copied
  from `kubectl create -o yaml` do emit `creationTimestamp: null`.)
- Every leaf — scalar, list or empty attrset — is defined with
  `lib.mkDefault`, and non-empty attrsets are recursed into. So a user's plain
  definition of a field wins over the chart's and attrsets (labels,
  `spec`, ...) merge; a list is replaced whole; a user's `null` removes a
  field (`render` drops nulls); `mkForce` isn't needed.
- `metadata.namespace`: the manifest's own, else `namespace`, for kinds that
  are namespaced or undeclared; never for cluster-scoped kinds, even when the
  manifest sets one (kubectl ignores it there; catenix's types reject it).
  This is what `kubectl apply -n <namespace>` and Helm do, both going by the
  server's scope for the kind; here the scope comes from the evaluated
  configuration, `config.kinds.<group>.<version>.<Kind>.namespaced` (set by
  `resourceModule`, see above), so core kinds, imported CRDs and the chart's
  own CRDs are all known. An undeclared kind (accepted, untyped, only without
  `validation.strict`) is assumed namespaced: most custom kinds are, and a
  cluster-scoped object's namespace is ignored by kubectl. Leaving it to the
  user was rejected: charts rely on `helm install -n` for the namespace of
  most objects, so every chart would need per-object overrides.
- Helm hooks (`helm.sh/hook` annotation) are kept as ordinary objects, the
  annotation included, unless `noHooks` (drops every hook) or `skipTests`
  (drops hooks with a `test` or legacy `test-success` event), mirroring
  `helm template --no-hooks`/`--skip-tests`.

Throws on a manifest without `apiVersion`, `kind` or `metadata.name`
(`generateName` isn't supported: the name is the key), and on two manifests
with the same group/version/kind/name — even in different namespaces, since a
resource key holds one object. The module reads `config.kinds` only inside
values (a plain `if`, not `mkIf`: even a disabled definition of an option a
typed cluster-scoped `metadata` doesn't declare is an error).

### `lib/importChart.nix` → `importChart { pkgs, chart, release, values ? { }, kubeVersion ? null, apiVersions ? [ ], includeCrds ? true, extraArgs ? [ ], patch ? (m: m), noHooks ? false, skipTests ? false }`

A Helm chart as a module. `helmTemplate` (the first eight arguments) renders
it; the JSON array is read back with `builtins.fromJSON (builtins.readFile
...)` — import-from-derivation, like `yaml2json`. `patch` maps each manifest
(return `null` to drop one), before anything else, so a patched CRD types
what it defines. The chart's `apiextensions.k8s.io/v1`
CustomResourceDefinitions (from `crds/` with `includeCrds`, or templated) are
imported with `crd.loadCrds` + `resourceModule.mkResourceModule`, so the
chart's custom resources are typed (and declared, so strict mode accepts
them); they are also emitted as resources themselves. Every manifest then
goes through `manifestsToResources` with `namespace = release.namespace or
"default"` and `noHooks`/`skipTests`. The module's `_file` is `helm release
<name> (chart <chart>)`, so a type error names the release. It sets `imports`
only, so it is itself imported (`pkgs` must then come from `specialArgs`,
as with `importCrdModule`).

A kind declared twice fails with the module system's "already declared"
error: don't also `importCrdModule` the chart's CRDs (or import two releases
of a chart shipping CRDs; drop them from the second with `includeCrds =
false` or `patch`).

### `modules/resources.nix`

`options.validation.strict` (`mkEnableOption`, default `false`) and
`options.resources` as a submodule whose `freeformType` is `null` when strict,
else `attrsOf (attrsOf (attrsOf (attrsOf (attrsOf anything))))` — so unknown
groups/kinds are accepted unless strict. Merges with the submodule
declarations from `resourceModule`. For that merge to work, every other
declaration of `options.resources` (each `resourceModule`) sets only `type`, as
a plain `types.submodule` with no `freeformType`, whose group and version
levels are nested option sets and whose first real option is the kind — this
module owns `default`, `description`, and the freeform type. It also owns the
`default = { }` of `options.kinds` (internal), whose per-kind options
`resourceModule` declares.

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

Fast loop: `nix develop -c nix-unit --flake .#tests.systems.<system>.unit.<unit>`.

## Known limitations

A manual smoke test applied rendered output to a real k3s v1.37 cluster (not
part of the repo). Everything that type-checked was accepted, apart from the
gaps below — catenix checks types, not every rule the API server enforces:

- **No enums for built-in kinds.** The checked-in OpenAPI v3 spec carries no
  `enum` constraints (the live server publishes them), so fields like
  `imagePullPolicy`, `Service.type`, `restartPolicy` or `pathType` accept any
  string. CRD enums are enforced.
- **Built-in kinds carry few string constraints.** The spec declares only
  `byte` (`Secret.data`, checked) and `date-time` formats; quantities
  (`cpu = "lots"`), names and label syntax are Go validation, not schema.
  CRD `pattern`, lengths, counts and formats are checked, with gaps:
  patterns using `(?i)`-style flags, `\b` or Unicode classes aren't (the
  type's description says so), nor are `uri`/`email`/IP formats, nor
  patterns and unbounded formats on values over 8192 bytes. The regex engine
  backtracks, unlike RE2, so a pathological pattern (`^(a+)+$`) on a long
  non-matching value can be slow.
- **Validation outside the schema** (selector/template label agreement, port
  ranges, duplicate list-map keys, named-port rules) is the server's job.
- **CRD `metadata` is untyped** when the CRD declares none (the usual case):
  `metadata.labels.tier = 5` type-checks but doesn't decode on the server.
- **Default-served versions are recognized by name** (`apis = "default"`
  keeps GA `v<N>` versions). That matches the pinned v1.37, where every
  alpha/beta group/version is off by default, but not older Kubernetes, where
  some betas were on (e.g. `batch/v1beta1` `CronJob` and `policy/v1beta1`
  before 1.25): pinned to such a release, "default" would leave them out.
  Per-resource enablement inside a GA group/version isn't modelled either. A kind in a left-out version is still accepted, untyped, by
  the freeform `resources` unless `validation.strict = true`.
- **Fields behind disabled feature gates are typed** (e.g. `emptyDir.mode`,
  `volumeMounts[].bindMountOptions`, `configMap.defaultUser`) and silently
  dropped by the server; so are enum values behind gates (toleration
  `operator: Gt`), which the spec has no enums for anyway. There's no reliable
  marker: descriptions say "(Alpha)", "This is an alpha field", "This field is
  alpha", "alpha-level" or "Alpha, gated by", but in v1.37 about one in six
  such fields is stale or misleading — `PodSpec.resources`,
  `PodSecurityContext.supplementalGroupsPolicy` and
  `VolumeProjection.clusterTrustBundle` say alpha while their gates are on by
  default, and `PersistentVolumeClaimSpec.dataSourceRef` (GA) is marked for its
  alpha `namespace` subfield. Dropping them would reject valid manifests, so
  catenix types every field. Feature-gate defaults live only in Go source
  (`pkg/features/kube_features.go`).
- **Unknown kinds type-check unless `validation.strict = true`**, so a kind
  typo (`Deploymnet`) only fails at apply time in the default mode.
- **Custom resources and their CRD in one `kubectl apply`** need two passes:
  output puts CRDs before other objects, but kubectl resolves every object's
  kind before creating any, so the custom resources fail the first time.
  Namespaces-first does make everything else apply in one pass.
- **YAML merge keys in CRD files** follow the YAML spec (keys written next to
  `<<` win). kubectl instead lets a merge written *after* an explicit key
  override it, so a CRD that does that is typed differently from what the
  server stores. Merges written first agree.
- **A `_module` key can't be set** inside a CRD object that has both
  `properties` and `x-kubernetes-preserve-unknown-fields`: the module system
  reserves that name in submodules. Elsewhere (e.g. `ConfigMap.data`) it's
  fine.
