# UTF-8 at the byte level. Nix strings are byte strings (`stringLength`,
# `substring` and regexes work on bytes), while Kubernetes counts and matches
# characters (Unicode code points).
#
# Nix has no escape for a single byte, so the lone bytes below are cut out of
# multibyte characters with `substring`.
{ lib }:
let
  # The character U+<hex>, as UTF-8.
  character = hex: builtins.fromJSON ''"\u${hex}"'';

  # U+0080 + i is encoded as C2 (80 + i): its second byte, for i < 64, is
  # every continuation byte in turn.
  continuationBytes = lib.genList (
    i: builtins.substring 1 1 (character (lib.fixedWidthString 4 "0" (lib.toHexString (128 + i))))
  ) 64;

  # Continuation bytes are 80..BF, a code point's first byte is ASCII or a
  # lead byte C2..F4 (C0, C1 and F5..FF never occur in UTF-8).
  continuationMin = builtins.head continuationBytes;
  continuationMax = lib.last continuationBytes;
  leadMin = builtins.substring 0 1 (character "0080");
  # U+100000 (a surrogate pair in JSON) is F4 80 80 80.
  leadMax = builtins.substring 0 1 (builtins.fromJSON ''"􀀀"'');

  noContinuationBytes = map (_: "") continuationBytes;

  # Code points in `s`: its bytes, less the continuation bytes (for valid
  # UTF-8; Go's utf8.RuneCount, which Kubernetes uses, agrees there).
  length = s: builtins.stringLength (builtins.replaceStrings continuationBytes noContinuationBytes s);
in
{
  inherit
    continuationBytes
    continuationMin
    continuationMax
    leadMin
    leadMax
    length
    ;

  # Whether `s` is all ASCII (no multibyte characters).
  isAscii = s: length s == builtins.stringLength s;
}
