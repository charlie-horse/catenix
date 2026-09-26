# Test wiring, as a flake-parts module.
#
# The system-agnostic suites (tests/agnostic.nix) are the flake's `tests`
# output; nix-unit's flake-parts module copies them into every system's
# `tests.systems.<system>.system-agnostic` (`enableSystemAgnostic`) and runs
# them in the sandboxed `checks.<system>.nix-unit`, with the flake inputs
# passed in through `nix-unit.inputs`.
#
# The per-system suites (tests/per-system.nix) read a derivation's output back
# at evaluation time (import-from-derivation), which that sandbox can't build.
# They're exposed as `legacyPackages.<system>.perSystemTests` for nix-unit and
# evaluated during `nix flake check` itself, one named check each
# (`<group>-<suite>`, e.g. `unit-yaml2json`, `contracts-cert-manager`), with
# `lib.debug.runTests` over the same `{ expr, expected }` cases.
#
# `legacyPackages.<system>.recordings.<name>` builds each recording in
# tests/fixtures/recorded afresh from its real call (tests/recordings.nix).
{
  inputs,
  self,
  lib,
  ...
}:
let
  suiteArgs = {
    inherit lib;
    catenix = self.lib;
    # One fixed system's nixpkgs, for suites that only instantiate derivations.
    referencePkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
    kubernetesSrc = inputs.kubernetes-src;
    certManagerChart = inputs.cert-manager-chart;
    catenixModule = self.nixosModules.default;
  };

  helpers = import ./helpers.nix { inherit lib; };

  recordings = import ./recordings.nix {
    inherit (suiteArgs) catenix kubernetesSrc certManagerChart;
    fixtures = ./fixtures;
  };
in
{
  flake.tests = import ./agnostic.nix suiteArgs;

  perSystem =
    { pkgs, ... }:
    let
      perSystemTests = import ./per-system.nix (suiteArgs // { inherit pkgs; });

      # A check that passes when every case of `suite` does, evaluated while
      # `nix flake check` evaluates the check itself.
      evalTime =
        name: suite:
        let
          failures = lib.debug.runTests suite;
        in
        if failures == [ ] then
          pkgs.runCommand name { } "touch $out"
        else
          throw "${name} failed:\n${lib.concatMapStringsSep "\n" describe failures}";

      # A failure as where the result first differs from the expectation
      # (recordings are too large to print whole).
      describe =
        failure:
        let
          difference = helpers.firstDifference failure.expected failure.result;
          pretty = lib.generators.toPretty { };
        in
        "${failure.name}: differs at ${
          if difference.path == "" then "the top" else difference.path
        }\n  expected: ${pretty difference.expected}\n  result:   ${pretty difference.actual}";
    in
    {
      nix-unit = {
        package = pkgs.nix-unit;
        inputs = {
          inherit (inputs)
            nixpkgs
            flake-parts
            nix-unit
            kubernetes-src
            cert-manager-chart
            ;
        };
      };

      legacyPackages = {
        inherit perSystemTests;

        # `cp $(nix build --print-out-paths .#legacyPackages.<system>.recordings.<name>)
        # tests/fixtures/recorded/<name>.json` re-records one.
        recordings = lib.mapAttrs (
          name: real:
          pkgs.runCommand "${name}.json" {
            nativeBuildInputs = [ pkgs.jq ];
            json = builtins.toJSON (real pkgs);
            passAsFile = [ "json" ];
          } ''jq . "$jsonPath" > "$out"''
        ) recordings;
      };

      checks = lib.concatMapAttrs (
        group:
        lib.mapAttrs' (
          suite: cases: lib.nameValuePair "${group}-${suite}" (evalTime "${group}-${suite}" cases)
        )
      ) perSystemTests;
    };
}
