# `fetchChart pkgs { repo, name, version, hash }`: a published Helm chart,
# pulled with the official CLI (`helm pull --untar`) in a fixed-output
# derivation whose output is the unpacked chart directory (subcharts
# included, as published), ready for `helmTemplate`/`importChart`.
#
# `repo` is a classic chart repository URL (`https://charts.jetstack.io`,
# pulled with `--repo`) or an OCI registry path (`oci://ghcr.io/org/charts`,
# the chart being `<repo>/<name>`). `hash` is the NAR hash of the unpacked
# directory: build once with `lib.fakeHash` and copy the one Nix reports.
# Proxy variables (and `NIX_SSL_CERT_FILE`, for proxies with their own CA) come
# from the environment, as with nixpkgs' fetchers.
#
# A classic repository's `.tgz` can instead be a flake input, which Nix
# fetches and unpacks itself (the same directory, so the same hash):
#
#   inputs.cert-manager-chart = {
#     url = "tarball+https://charts.jetstack.io/charts/cert-manager-v1.21.2.tgz";
#     flake = false;
#   };
{ lib }:
pkgs:
{
  repo,
  name,
  version,
  hash,
}:
let
  oci = lib.hasPrefix "oci://" repo;
in
if !(oci || lib.hasPrefix "https://" repo || lib.hasPrefix "http://" repo) then
  throw "fetchChart: repo must be an http(s):// chart repository or an oci:// registry, not `${repo}'"
else
  pkgs.runCommand (lib.strings.sanitizeDerivationName "helm-chart-${name}-${version}")
    {
      nativeBuildInputs = [ pkgs.kubernetes-helm ];
      chartRef = if oci then "${lib.removeSuffix "/" repo}/${name}" else name;
      repo = if oci then "" else repo;
      inherit version;
      outputHashMode = "recursive";
      outputHash = hash;
      impureEnvVars = lib.fetchers.proxyImpureEnvVars;
      cacert = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    }
    ''
      export HOME="$TMPDIR"
      export HELM_CACHE_HOME="$TMPDIR/helm/cache"
      export HELM_CONFIG_HOME="$TMPDIR/helm/config"
      export HELM_DATA_HOME="$TMPDIR/helm/data"
      export SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-$cacert}"

      helm pull "$chartRef" ''${repo:+--repo "$repo"} --version "$version" --untar --untardir "$TMPDIR/pulled"
      mv "$TMPDIR"/pulled/* "$out"
    ''
