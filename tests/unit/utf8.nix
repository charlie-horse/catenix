# Unit tests for lib/utf8.nix: code point counting and the byte-level
# building blocks regexes over UTF-8 text need.
{ catenix, ... }:
let
  inherit (catenix) utf8;
in
{
  testLengthAscii = {
    expr = utf8.length "hello";
    expected = 5;
  };

  testLengthEmpty = {
    expr = utf8.length "";
    expected = 0;
  };

  # 2-, 3- and 4-byte sequences each count once.
  testLengthMultibyte = {
    expr = map utf8.length [
      "héllo"
      "日本語"
      "a😀b"
      "µs"
    ];
    expected = [
      5
      3
      3
      2
    ];
  };

  testLengthIsNotByteLength = {
    expr = builtins.stringLength "日本語";
    expected = 9;
  };

  testIsAscii = {
    expr = map utf8.isAscii [
      ""
      "abc ~\n"
      "é"
      "a😀"
    ];
    expected = [
      true
      true
      false
      false
    ];
  };

  # Lone bytes: one byte each, at the ends of the continuation and lead ranges.
  testByteLengths = {
    expr = map builtins.stringLength [
      utf8.continuationMin
      utf8.continuationMax
      utf8.leadMin
      utf8.leadMax
    ];
    expected = [
      1
      1
      1
      1
    ];
  };

  testContinuationBytesCount = {
    expr = builtins.length utf8.continuationBytes;
    expected = 64;
  };

  # "é" is C3 A9: the lead byte falls in [leadMin, leadMax], the second byte
  # is a continuation byte.
  testBytesClassifyMultibyte = {
    expr =
      let
        lead = builtins.substring 0 1 "é";
        cont = builtins.substring 1 1 "é";
        within =
          min: max: b:
          builtins.match "[${min}-${max}]" b != null;
      in
      {
        leadIsLead = within utf8.leadMin utf8.leadMax lead;
        contIsCont = within utf8.continuationMin utf8.continuationMax cont;
        contIsNotLead = within utf8.leadMin utf8.leadMax cont;
        asciiIsNotCont = within utf8.continuationMin utf8.continuationMax "a";
      };
    expected = {
      leadIsLead = true;
      contIsCont = true;
      contIsNotLead = false;
      asciiIsNotCont = false;
    };
  };
}
