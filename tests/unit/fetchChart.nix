# Unit tests for lib/fetchChart.nix: `helm pull` as a fixed-output
# derivation. Fetching needs the network, so only the derivation is checked
# here (sandbox-safe); the pull itself was checked by hand (DESIGN.md).
{
  lib,
  catenix,
  pkgs,
  helpers,
  ...
}:
let
  fetchChart = catenix.fetchChart pkgs;

  hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

  classic = fetchChart {
    repo = "https://charts.jetstack.io";
    name = "cert-manager";
    version = "v1.21.2";
    inherit hash;
  };

  oci = fetchChart {
    repo = "oci://registry-1.docker.io/bitnamicharts/";
    name = "redis";
    version = "20.0.0";
    inherit hash;
  };
in
{
  testFixedOutput = {
    expr = {
      inherit (classic) name outputHash outputHashMode;
      isDerivation = lib.isDerivation classic;
    };
    expected = {
      name = "helm-chart-cert-manager-v1.21.2";
      outputHash = hash;
      outputHashMode = "recursive";
      isDerivation = true;
    };
  };

  testClassicRepository = {
    expr = {
      inherit (classic) chartRef repo version;
    };
    expected = {
      chartRef = "cert-manager";
      repo = "https://charts.jetstack.io";
      version = "v1.21.2";
    };
  };

  testOciRegistry = {
    expr = {
      inherit (oci) chartRef repo;
    };
    expected = {
      chartRef = "oci://registry-1.docker.io/bitnamicharts/redis";
      repo = "";
    };
  };

  testUsesProxySettings = {
    expr = lib.all (v: lib.elem v classic.impureEnvVars) [
      "https_proxy"
      "HTTPS_PROXY"
      "NIX_SSL_CERT_FILE"
    ];
    expected = true;
  };

  testRejectsOtherRepositories = {
    expr =
      helpers.fails
        (fetchChart {
          repo = "charts.jetstack.io";
          name = "cert-manager";
          version = "v1.21.2";
          inherit hash;
        }).drvPath;
    expected = true;
  };
}
