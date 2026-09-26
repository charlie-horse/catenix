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

  # Where two unequal values first differ, as `{ path, expected, actual }`
  # (`path` like `[0].spec.size`), or null when they are equal: a readable
  # failure for large values such as recordings.
  firstDifference =
    let
      at =
        path: expected: actual:
        let
          first = lib.findFirst (d: d != null) null;
          here = { inherit path expected actual; };
        in
        if expected == actual then
          null
        else if lib.isAttrs expected && lib.isAttrs actual then
          let
            names = lib.unique (lib.attrNames expected ++ lib.attrNames actual);
          in
          lib.defaultTo here (
            first (
              map (
                name: at "${path}.${name}" (expected.${name} or "<absent>") (actual.${name} or "<absent>")
              ) names
            )
          )
        else if lib.isList expected && lib.isList actual then
          let
            common = lib.min (lib.length expected) (lib.length actual);
          in
          lib.defaultTo
            {
              path = "${path} (length)";
              expected = lib.length expected;
              actual = lib.length actual;
            }
            (
              first (
                lib.genList (i: at "${path}[${toString i}]" (lib.elemAt expected i) (lib.elemAt actual i)) common
              )
            )
        else
          here;
    in
    at "";
}
