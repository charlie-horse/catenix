# Unit tests for lib/pattern.nix: translating the RE2 regexes Kubernetes
# checks `pattern` with (searched, unanchored) into POSIX EREs for
# `builtins.match` (whole string), or refusing to.
{ lib, catenix, ... }:
let
  inherit (catenix.pattern) translate matcher inputLimit;

  # Whether `pattern` finds a match in each of `values`.
  search = pattern: map (matcher pattern);
  translates = pattern: translate pattern != null;

  # Real patterns: every distinct `pattern` in the CRDs shipped in the pinned
  # kubernetes-src (Gateway API, Calico, volume snapshots, apiextensions test
  # CRDs), then common ones from widely used CRDs.
  kubernetesSrcCorpus = [
    "^$|^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$"
    "^([a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*/)?(([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9])$"
    "^([a-z0-9][-a-z0-9_.]*)?[a-z0-9]$"
    "^(\\*\\.)?[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$"
    "^(\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))))?$"
    "^(\\d+):(\\d+)$|^(\\d+):(\\d+):(\\d+)$"
    "^(|[a-z0-9]([-a-z0-9]*[a-z0-9](\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*)?)$"
    "^.*"
    "^Hostname|IPAddress|NamedAddress|[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\\/[A-Za-z0-9\\/\\-._~%!$&'()*+,;=:]+$"
    "^[A-Za-z0-9!#$%&'*+\\-.^_\\x60|~]+$"
    "^[A-Za-z]([A-Za-z0-9_,:]*[A-Za-z0-9_])?$"
    "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$"
    "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$"
    "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\\/[A-Za-z0-9\\/\\-._~%!$&'()*+,;=:]+$"
    "^[a-zA-Z0-9]([-a-zSA-Z0-9]*[a-zA-Z0-9])?$|[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\\/[A-Za-z0-9]+$"
    "^[a-zA-Z]([-a-zA-Z0-9]*[a-zA-Z0-9])?$"
    "^[a-z][-a-z0-9]*[a-z0-9]$"
  ];

  commonCorpus = [
    # Gateway API durations, paths, header names
    "^([0-9]{1,5}(h|m|s|ms)){1,4}$"
    "^/[a-zA-Z0-9\\-._~!$&'()*+,;=:@/%]*$"
    "^(?:[A-Za-z0-9!#$%&'*+\\-.^_`|~]+)$"
    # Prometheus operator duration
    "^(0|(([0-9]+)y)?(([0-9]+)w)?(([0-9]+)d)?(([0-9]+)h)?(([0-9]+)m)?(([0-9]+)s)?(([0-9]+)ms)?)$"
    # semver (semver.org), with non-capturing groups
    "^v?(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-((?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\\.(?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\\+([0-9a-zA-Z-]+(?:\\.[0-9a-zA-Z-]+)*))?$"
    # semver with a named group (Go syntax)
    "^(?P<major>0|[1-9]\\d*)\\.(?P<minor>0|[1-9]\\d*)\\.(?P<patch>0|[1-9]\\d*)$"
    # cert-manager-ish, Crossplane, Argo, Flux
    "^[a-zA-Z0-9_.-]+$"
    "^\\S+$"
    "^\\w+$"
    "^[^\\s]+$"
    "^([0-9]+(\\.[0-9]+)?(ms|s|m|h))+$"
    "^(http|https)://.*$"
    "^arn:aws[a-z-]*:iam::\\d{12}:role/.+$"
    "^([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9]$"
    "^[0-9]+(\\.[0-9]+)?%$"
    "^(\\*|\\d+(-\\d+)?)$"
    "^\\d+(\\.\\d+)?(Ki|Mi|Gi)?$"
    "^(Always|Never|IfNotPresent)$"
    "[a-z]"
    # RE2 features with no faithful POSIX equivalent
    "(?i)^[a-z]+$"
    "^\\bword\\b$"
    "^\\p{L}+$"
    "^[\\p{Lu}]+$"
    "^(?s).*$"
  ];

  translated = lib.filter translates;
in
{
  # Anchors and searching

  testUnanchoredSearchesAnywhere = {
    expr = search "b+" [
      "abbbc"
      "b"
      "ac"
      ""
    ];
    expected = [
      true
      true
      false
      false
    ];
  };

  testAnchoredStart = {
    expr = search "^ab" [
      "abc"
      "cab"
    ];
    expected = [
      true
      false
    ];
  };

  testAnchoredEnd = {
    expr = search "ab$" [
      "cab"
      "abc"
    ];
    expected = [
      true
      false
    ];
  };

  # RE2's `$` (without the m flag) matches only at the very end of the text,
  # not before a final newline.
  testDollarIsEndOfText = {
    expr = search "a$" [
      "a"
      "a\n"
    ];
    expected = [
      true
      false
    ];
  };

  testEmptyPatternMatchesEverything = {
    expr = search "" [
      ""
      "anything"
      "multi\nline"
    ];
    expected = [
      true
      true
      true
    ];
  };

  # The DNS-1123 label, fully anchored.
  testDns1123Label = {
    expr = search "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" [
      "a"
      "my-app-1"
      "-app"
      "app-"
      "App"
      ""
      "a.b"
    ];
    expected = [
      true
      true
      false
      false
      false
      false
      false
    ];
  };

  # Top-level alternation binds loosest: `^a|b$` is "starts with a, or ends with b".
  testTopLevelAlternationAnchorsEachBranch = {
    expr = search "^a|b$" [
      "ax"
      "xb"
      "xa"
      "bx"
    ];
    expected = [
      true
      true
      false
      false
    ];
  };

  # The Gateway API pattern whose `^`/`$` only anchor the first/last branch.
  testGatewayAddressTypeQuirk = {
    expr =
      search
        "^Hostname|IPAddress|NamedAddress|[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*\\/[A-Za-z0-9\\/\\-._~%!$&'()*+,;=:]+$"
        [
          "Hostname"
          "IPAddress"
          "xxIPAddressxx"
          "example.com/Custom"
          "Custom"
        ];
    expected = [
      true
      true
      true
      true
      false
    ];
  };

  testAnchorsInsideGroups = {
    expr = search "(^a|b)c" [
      "acx"
      "xbc"
      "xac"
    ];
    expected = [
      true
      true
      false
    ];
  };

  testEscapedAnchorsAreLiteral = {
    expr = search "^\\^\\$$" [
      "^$"
      ""
    ];
    expected = [
      true
      false
    ];
  };

  testTextAnchors = {
    expr = search "\\Aab\\z" [
      "ab"
      "xab"
      "abx"
    ];
    expected = [
      true
      false
      false
    ];
  };

  # Perl classes, outside and inside brackets

  testPerlClasses = {
    expr = {
      d = search "^\\d+$" [
        "0123456789"
        "1a"
      ];
      D = search "^\\D+$" [
        "ab-"
        "a1"
      ];
      w = search "^\\w+$" [
        "a_Z9"
        "a-b"
      ];
      W = search "^\\W+$" [
        "-+ "
        "-a"
      ];
      s = search "^a\\sb$" [
        "a b"
        "a\tb"
        "a\nb"
        "ab"
      ];
      S = search "^\\S+$" [
        "abc"
        "a b"
      ];
    };
    expected = {
      d = [
        true
        false
      ];
      D = [
        true
        false
      ];
      w = [
        true
        false
      ];
      W = [
        true
        false
      ];
      s = [
        true
        true
        true
        false
      ];
      S = [
        true
        false
      ];
    };
  };

  # RE2's \s is [\t\n\f\r ]: no vertical tab, unlike POSIX [:space:].
  testSpaceHasNoVerticalTab = {
    expr = search "^\\s$" [ "\t" ] ++ search "^\\s$" [ (builtins.fromJSON ''"\u000b"'') ];
    expected = [
      true
      false
    ];
  };

  testPerlClassesInBrackets = {
    expr = {
      digitsOrDash = search "^[\\d-]+$" [
        "12-3"
        "1a"
      ];
      notSpace = search "^[\\S]+$" [
        "ab"
        "a b"
      ];
      wordOrDot = search "^[\\w.]+$" [
        "a.b_c"
        "a/b"
      ];
    };
    expected = {
      digitsOrDash = [
        true
        false
      ];
      notSpace = [
        true
        false
      ];
      wordOrDot = [
        true
        false
      ];
    };
  };

  testPosixClassesInBrackets = {
    expr = search "^[[:alpha:][:digit:]_]+$" [
      "ab_12"
      "a-b"
    ];
    expected = [
      true
      false
    ];
  };

  testNegatedPosixClassInBrackets = {
    expr = search "^[[:^digit:]]+$" [
      "ab"
      "a1"
    ];
    expected = [
      true
      false
    ];
  };

  # Brackets

  testBracketSpecialCharacters = {
    expr = search "^[]a^\\\\[-]+$" [
      "]a^\\[-"
      "b"
    ];
    expected = [
      true
      false
    ];
  };

  testBracketEscapes = {
    expr = search "^[\\]\\-\\^\\[\\.]+$" [
      "]-^[."
      "a"
    ];
    expected = [
      true
      false
    ];
  };

  testBracketCaretOnly = {
    expr = search "^[\\^]$" [
      "^"
      "a"
    ];
    expected = [
      true
      false
    ];
  };

  testBracketCaretAndDash = {
    expr = search "^[\\^-]+$" [
      "^-"
      "a"
    ];
    expected = [
      true
      false
    ];
  };

  testNegatedBracket = {
    expr = search "^[^/]+$" [
      "abc"
      "a/b"
      "a\nb"
    ];
    expected = [
      true
      false
      true
    ];
  };

  # With Perl flags, as Kubernetes compiles them, `-` is literal after a range.
  testDashAfterRangeIsLiteral = {
    expr = search "^[a-c-e]+$" [
      "a-e"
      "d"
    ];
    expected = [
      true
      false
    ];
  };

  testRangeOfPunctuation = {
    expr = search "^[!-/]+$" [
      "!/*"
      "a"
    ];
    expected = [
      true
      false
    ];
  };

  testHexEscapes = {
    expr = search "^[\\x60]\\x41\\x{42}$" [
      "`AB"
      "xAB"
    ];
    expected = [
      true
      false
    ];
  };

  testControlEscapes = {
    expr = search "^a\\tb\\nc$" [ "a\tb\nc" ];
    expected = [ true ];
  };

  testEscapedPunctuation = {
    expr = search "^\\.\\*\\+\\?\\(\\)\\[\\]\\{\\}\\|\\\\\\/$" [
      ".*+?()[]{}|\\/"
      "a*+?()[]{}|\\/"
    ];
    expected = [
      true
      false
    ];
  };

  testLiteralBraces = {
    expr = search "^a{,2}}$" [
      "a{,2}}"
      "aa"
    ];
    expected = [
      true
      false
    ];
  };

  # Quantifiers

  testCountedRepetition = {
    expr = search "^a{2,3}$" [
      "a"
      "aa"
      "aaa"
      "aaaa"
    ];
    expected = [
      false
      true
      true
      false
    ];
  };

  testCountedRepetitionForms = {
    expr =
      (search "^a{2}$" [
        "aa"
        "aaa"
      ])
      ++ (search "^a{2,}$" [
        "a"
        "aaaa"
      ]);
    expected = [
      true
      false
      false
      true
    ];
  };

  # Lazy quantifiers find a match exactly when greedy ones do.
  testLazyQuantifiers = {
    expr = search "^a+?b*?c??d{1,2}?$" [
      "abd"
      "aad"
      "abce"
    ];
    expected = [
      true
      true
      false
    ];
  };

  testNonCapturingGroup = {
    expr = search "^(?:ab)+$" [
      "abab"
      "aba"
    ];
    expected = [
      true
      false
    ];
  };

  testNamedGroups = {
    expr = search "^(?P<a>x)(?<b>y)$" [
      "xy"
      "yx"
    ];
    expected = [
      true
      false
    ];
  };

  testEmptyAlternatives = {
    expr = search "^(|a)b$" [
      "b"
      "ab"
      "aab"
    ];
    expected = [
      true
      true
      false
    ];
  };

  # `.` is any character but newline, one character (not byte) at a time.

  testDotExcludesNewline = {
    expr = search "^a.b$" [
      "axb"
      "a\nb"
    ];
    expected = [
      true
      false
    ];
  };

  testDotMatchesOneCharacter = {
    expr = search "^.{3}$" [
      "abc"
      "héé"
      "日本語"
      "a😀b"
      "ab"
      "日本語x"
    ];
    expected = [
      true
      true
      true
      true
      false
      false
    ];
  };

  testNegatedClassMatchesOneCharacter = {
    expr = search "^[^a]x$" [
      "éx"
      "😀x"
      "ax"
    ];
    expected = [
      true
      true
      false
    ];
  };

  testNegatedPerlClassMatchesOneCharacter = {
    expr = search "^\\D\\S\\W$" [
      "é日😀"
      "1日😀"
    ];
    expected = [
      true
      false
    ];
  };

  testMultibyteValueAgainstAsciiPattern = {
    expr = search "^[a-z]+$" [
      "abc"
      "abé"
    ];
    expected = [
      true
      false
    ];
  };

  # Refusals: null, so the pattern goes unchecked

  testRefusesUnsupported = {
    expr = map translate [
      "(?i)abc" # flags
      "(?s:a.b)"
      "a(?=b)" # lookarounds (RE2 rejects them anyway)
      "a(?!b)"
      "(?<=a)b"
      "(?<!a)b"
      "(a)\\1" # backreferences
      "\\bword\\b" # word boundaries
      "\\Bx"
      "\\p{L}" # Unicode classes
      "\\PL"
      "[\\p{Lu}]"
      "\\Qa.b\\E" # quoting
      "\\C"
      "é+" # non-ASCII pattern text
      "\\x{e9}" # non-ASCII escapes
      "\\0"
    ];
    expected = lib.genList (_: null) 17;
  };

  # Patterns RE2 itself rejects (and so a CRD can't carry) are refused too,
  # never turned into an invalid ERE, which would abort evaluation.
  testRefusesInvalid = {
    expr = map translate [
      "("
      "a)"
      "[a"
      "[z-a]"
      "*a"
      "a**"
      "a{2}{3}"
      "a{3,2}"
      "a{1001}"
      "\\"
      "\\q"
      "[[:foo:]]"
      "x{2}+"
    ];
    expected = lib.genList (_: null) 13;
  };

  testRefusesQuantifiedAnchors = {
    expr = map translate [
      "^*a"
      "a$+"
    ];
    expected = [
      null
      null
    ];
  };

  # Counted repetitions blow up into copies in the compiled automaton; too
  # many would make `builtins.match` fail evaluation, so they're refused.
  testRefusesOversizedRepetitions = {
    expr = map translates [
      "^(a{1,200}b){1,100}$"
      "^a{1,1000}$"
    ];
    expected = [
      false
      true
    ];
  };

  testMatcherIsNullWhenRefused = {
    expr = matcher "(?i)x";
    expected = null;
  };

  # Longer values would overflow the regex engine's stack, so they're accepted
  # unchecked.
  testLongValuesAreNotChecked = {
    expr =
      let
        long = lib.concatStrings (lib.genList (_: "x") (inputLimit + 1));
      in
      search "^a" [
        long
        (builtins.substring 0 inputLimit long)
      ];
    expected = [
      true
      false
    ];
  };

  testTranslationIsAnEre = {
    expr = translate "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$";
    expected = "(^[0-9a-z]([0-9a-z-]*[0-9a-z])?$)";
  };

  testUnanchoredTranslationIsWrapped = {
    expr = translate "a|b";
    expected = ".*(a|b).*";
  };

  # The corpus

  testKubernetesSrcCorpusTranslates = {
    expr = lib.filter (p: !translates p) kubernetesSrcCorpus;
    expected = [ ];
  };

  testCommonCorpusCoverage = {
    expr = {
      total = builtins.length commonCorpus;
      translated = builtins.length (translated commonCorpus);
      refused = lib.filter (p: !translates p) commonCorpus;
    };
    expected = {
      total = 24;
      translated = 19;
      refused = [
        "(?i)^[a-z]+$"
        "^\\bword\\b$"
        "^\\p{L}+$"
        "^[\\p{Lu}]+$"
        "^(?s).*$"
      ];
    };
  };

  # Every translation is a valid ERE: matching it never aborts evaluation.
  testCorpusTranslationsCompile = {
    expr = map (p: builtins.isBool (matcher p "x")) (translated (kubernetesSrcCorpus ++ commonCorpus));
    expected = lib.genList (_: true) (
      builtins.length (translated (kubernetesSrcCorpus ++ commonCorpus))
    );
  };

  testCorpusBehaviour = {
    expr = {
      quantity =
        search
          "^(\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))(([KMGTPE]i)|[numkMGTPE]|([eE](\\+|-)?(([0-9]+(\\.[0-9]*)?)|(\\.[0-9]+))))?$"
          [
            "100m"
            "1.5Gi"
            "1e3"
            "-.5"
            "lots"
            "1Gb"
          ];
      ports = search "^(\\d+):(\\d+)$|^(\\d+):(\\d+):(\\d+)$" [
        "80:8080"
        "1:2:3"
        "1:2:3:4"
      ];
      headerName = search "^[A-Za-z0-9!#$%&'*+\\-.^_\\x60|~]+$" [
        "X-Custom_Header"
        "`quoted`"
        "Bad Header"
        "Bad:Header"
      ];
      gatewayDuration = search "^([0-9]{1,5}(h|m|s|ms)){1,4}$" [
        "1h30m"
        "500ms"
        "1h1m1s1ms"
        "1h1m1s1ms1h"
        "123456s"
      ];
      semver =
        search
          "^v?(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-((?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\\.(?:0|[1-9]\\d*|\\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\\+([0-9a-zA-Z-]+(?:\\.[0-9a-zA-Z-]+)*))?$"
          [
            "1.2.3"
            "v1.2.3-rc.1+build.5"
            "01.2.3"
            "1.2"
          ];
      optionalSubdomain = search "^$|^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$" [
        ""
        "a.b-c.d"
        "a..b"
      ];
    };
    expected = {
      quantity = [
        true
        true
        true
        true
        false
        false
      ];
      ports = [
        true
        true
        false
      ];
      headerName = [
        true
        true
        false
        false
      ];
      gatewayDuration = [
        true
        true
        true
        false
        false
      ];
      semver = [
        true
        true
        false
        false
      ];
      optionalSubdomain = [
        true
        true
        false
      ];
    };
  };
}
