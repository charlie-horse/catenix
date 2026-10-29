# `helmTemplate pkgs { chart, release, values ? { }, kubeVersion ? null,
# apiVersions ? [ ], includeCrds ? true, extraArgs ? [ ] }`: a derivation
# rendering a Helm chart with the official CLI (`helm template`), whose output
# is one JSON array of the rendered manifests.
#
# `chart` is a local chart directory or `.tgz` (a path, store path or
# derivation such as `fetchChart`'s): the build has no network, so the chart's
# dependencies must already be vendored under its `charts/` directory, as they
# are in published chart archives. Helm refuses a chart whose declared
# dependency is missing there; the build then fails with Helm's message and a
# hint. `release` is `{ name; namespace ? "default"; }`. `values` are written
# as JSON (which is YAML) and passed with `--values`, over the chart's
# `values.yaml`. `kubeVersion` and `apiVersions` set `.Capabilities`
# (`--kube-version`, `--api-versions`; Helm's defaults otherwise).
#
# One pipeline: `helm template` splits and cleans the documents by Helm's own
# rules and prints them `---`-separated; yq reads that stream and writes the
# JSON array, dropping empty (comment-only) documents. yq parses YAML 1.2,
# Kubernetes (and Helm's own install path, `sigs.k8s.io/yaml`) YAML 1.1, so
# yq is told the two plain-scalar forms where they differ in a value: octal
# integers with a bare leading zero (`0644` is 420) and the booleans `y`,
# `yes`, `on`, `n`, `no`, `off` in their three casings. Quoted scalars and
# map keys are left alone.
{ lib }:
pkgs:
{
  chart,
  release,
  values ? { },
  kubeVersion ? null,
  apiVersions ? [ ],
  includeCrds ? true,
  extraArgs ? [ ],
}:
let
  args = [
    "template"
    release.name
    "${chart}"
    "--namespace"
    (release.namespace or "default")
  ]
  ++ lib.optional includeCrds "--include-crds"
  ++ lib.optionals (kubeVersion != null) [
    "--kube-version"
    kubeVersion
  ]
  ++ lib.concatMap (apiVersion: [
    "--api-versions"
    apiVersion
  ]) apiVersions
  ++ extraArgs;

  yaml11Booleans = boolean: words: ''
    | (.. | select(tag == "!!str" and style == "" and test("^(${words})$"))) |= ${boolean}
  '';

  # `[.]` collects every document of the stream into one array.
  toJson = ''
    [.] | map(select(. != null))
    | (.. | select(tag == "!!int" and style == "" and (to_string | test("^[-+]?0[0-7]+$"))))
        |= (to_string | sub("^(?P<sign>[-+]?)0"; "''${sign}0o") | . tag = "!!int")
  ''
  + yaml11Booleans "true" "y|Y|yes|Yes|YES|on|On|ON"
  + yaml11Booleans "false" "n|N|no|No|NO|off|Off|OFF";
in
pkgs.runCommand (lib.strings.sanitizeDerivationName "helm-template-${release.name}.json")
  {
    nativeBuildInputs = [
      pkgs.kubernetes-helm
      pkgs.yq-go
    ];
    values = builtins.toJSON values;
    passAsFile = [ "values" ];
    inherit toJson;
  }
  ''
    export HOME="$TMPDIR"
    export HELM_CACHE_HOME="$TMPDIR/helm/cache"
    export HELM_CONFIG_HOME="$TMPDIR/helm/config"
    export HELM_DATA_HOME="$TMPDIR/helm/data"

    helm ${lib.escapeShellArgs args} --values "$valuesPath" \
      | yq --output-format=json --indent=0 eval-all "$toJson" > "$out" \
      || {
        echo "helmTemplate: helm template failed for ${chart} (error above)." >&2
        echo "Builds have no network: dependencies must be vendored under the chart's charts/ directory (helm dependency build), as they are in published charts (fetchChart)." >&2
        exit 1
      }
  ''
