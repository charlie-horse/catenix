# Small helpers shared by test suites.
{ lib }:
{
  # Whether fully evaluating `value` succeeds. Module type errors and `throw`s
  # are catchable, so a failure case reads `expr = fails x; expected = true;`
  # under both nix-unit and `lib.debug.runTests`.
  fails = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  # Evaluates `modules` with `pkgs` available as a module argument, the way a
  # caller of `nixosModules.default` would.
  eval =
    pkgs: modules:
    lib.evalModules {
      modules = [ { _module.args.pkgs = pkgs; } ] ++ modules;
    };
}
