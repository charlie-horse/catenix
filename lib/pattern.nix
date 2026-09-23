# Translates the regexes Kubernetes checks `pattern` with into POSIX EREs for
# `builtins.match`, or refuses to.
#
# Kubernetes compiles `pattern` with Go's `regexp` (RE2 syntax, Perl flags)
# and searches for a match anywhere in the value; `builtins.match` takes a
# POSIX ERE (libstdc++'s dialect) and must match the whole string. A pattern
# is parsed and re-emitted atom by atom, anchors kept, and wrapped in `.*` on
# the sides not every top-level branch anchors. Anything without a faithful
# translation (flags, `\b`, Unicode classes, ...) or that RE2 itself would
# reject yields null, never an invalid ERE: a bad regex aborts evaluation
# rather than throwing.
#
# RE2 matches characters, the ERE bytes: patterns must be ASCII, and every
# class that admits non-ASCII characters (`.`, `[^a]`, `\D`, ...) matches a
# whole multibyte character with an extra lead-byte-plus-continuations branch.
{ lib, utf8 }:
let
  inherit (builtins)
    elemAt
    match
    stringLength
    substring
    ;

  # The ASCII character with code `n` (1..127) and the reverse lookup.
  chr = n: builtins.fromJSON ''"\u${lib.fixedWidthString 4 "0" (lib.toHexString n)}"'';
  asciiCodes = lib.range 1 127;
  codeOf = lib.listToAttrs (map (n: lib.nameValuePair (chr n) n) asciiCodes);

  # A character class: ASCII codes, plus whether it admits every non-ASCII
  # character (patterns are ASCII, so a class admits all of them or none).
  ascii = codes: {
    inherit codes;
    nonAscii = false;
  };
  single = n: ascii [ n ];
  union = a: b: {
    codes = a.codes ++ b.codes;
    nonAscii = a.nonAscii || b.nonAscii;
  };
  normalize =
    codes:
    let
      present = lib.genAttrs (map toString codes) (_: true);
    in
    lib.filter (n: present ? ${toString n}) asciiCodes;
  negate = class: {
    codes = lib.subtractLists (normalize class.codes) asciiCodes;
    nonAscii = !class.nonAscii;
  };

  digit = lib.range 48 57;
  upper = lib.range 65 90;
  lower = lib.range 97 122;
  word = digit ++ upper ++ lower ++ [ 95 ];
  # RE2's \s: [\t\n\f\r ] (no \v).
  space = [
    9
    10
    12
    13
    32
  ];

  perlClasses = {
    d = ascii digit;
    D = negate (ascii digit);
    w = ascii word;
    W = negate (ascii word);
    s = ascii space;
    S = negate (ascii space);
  };

  # RE2's ASCII-only POSIX classes.
  posixClasses = {
    alnum = digit ++ upper ++ lower;
    alpha = upper ++ lower;
    ascii = asciiCodes;
    blank = [
      9
      32
    ];
    cntrl = lib.range 1 31 ++ [ 127 ];
    inherit
      digit
      lower
      upper
      word
      ;
    graph = lib.range 33 126;
    print = lib.range 32 126;
    punct = lib.range 33 47 ++ lib.range 58 64 ++ lib.range 91 96 ++ lib.range 123 126;
    space = [
      9
      10
      11
      12
      13
      32
    ];
    xdigit = digit ++ lib.range 65 70 ++ lib.range 97 102;
  };

  controlEscapes = {
    a = 7;
    f = 12;
    t = 9;
    n = 10;
    r = 13;
    v = 11;
  };

  isAlnum = c: match "[0-9A-Za-z]" c != null;

  # One ASCII character as an ERE atom.
  literal =
    n:
    let
      c = chr n;
    in
    if
      lib.elem c [
        "."
        "("
        ")"
        "*"
        "+"
        "?"
        "{"
        "|"
        "^"
        "$"
      ]
    then
      "\\" + c
    else
      {
        "[" = "[[]";
        "]" = "[]]";
        "}" = "[}]";
        "\\" = "[\\]";
      }
      .${c} or c;

  # A bracket expression for a non-empty, sorted set of codes. In POSIX
  # brackets `\` is literal, `]` must come first, `-` last and `^` not first;
  # runs of digits or letters become ranges.
  bracket =
    codes:
    let
      has = n: lib.elem n codes;
      others = lib.filter (
        n:
        !(lib.elem n [
          45
          93
          94
        ])
      ) codes;
      category =
        n:
        if lib.elem n digit then
          "digit"
        else if lib.elem n upper then
          "upper"
        else if lib.elem n lower then
          "lower"
        else
          null;
      runs = lib.foldl' (
        acc: n:
        let
          last = lib.last acc;
        in
        if acc != [ ] && n == last.hi + 1 && category n != null && category n == category last.hi then
          lib.init acc ++ [ (last // { hi = n; }) ]
        else
          acc
          ++ [
            {
              lo = n;
              hi = n;
            }
          ]
      ) [ ] others;
      showRun =
        run:
        if run.hi - run.lo >= 2 then
          "${chr run.lo}-${chr run.hi}"
        else
          lib.concatMapStrings chr (lib.range run.lo run.hi);
    in
    if codes == [ 94 ] then
      "\\^"
    else if
      codes == [
        45
        94
      ]
    then
      "[-^]"
    else
      "["
      + lib.optionalString (has 93) "]"
      + lib.concatMapStrings showRun runs
      + lib.optionalString (has 94) "^"
      + lib.optionalString (has 45) "-"
      + "]";

  # Any one multibyte character.
  multibyte = "[${utf8.leadMin}-${utf8.leadMax}][${utf8.continuationMin}-${utf8.continuationMax}]*";

  # A class as an atom `{ out, weight }`, or null if it can't match anything.
  emitClass =
    class:
    let
      codes = normalize class.codes;
    in
    if codes == [ ] && !class.nonAscii then
      null
    else if !class.nonAscii && builtins.length codes == 1 then
      {
        out = literal (builtins.head codes);
        weight = 1;
      }
    else if !class.nonAscii then
      {
        out = bracket codes;
        weight = 1;
      }
    else if codes == [ ] then
      {
        out = "(${multibyte})";
        weight = 3;
      }
    else
      {
        out = "(${bracket codes}|${multibyte})";
        weight = 4;
      };

  # `.`: any character but newline.
  anyButNewline = {
    codes = lib.remove 10 asciiCodes;
    nonAscii = true;
  };

  # Past this many copies of atoms (counted repetitions multiply), libstdc++
  # could exceed its automaton size limit, which aborts evaluation.
  weightBudget = 10000;

  # Values longer than this many bytes aren't matched: libstdc++'s regex
  # matcher recurses per character and overflows the stack on long input.
  inputLimit = 8192;

  bind = x: f: if x == null then null else f x;

  translate =
    pattern:
    let
      chars = lib.stringToCharacters pattern;
      n = builtins.length chars;
      at = i: if i < n then elemAt chars i else null;
      rest = i: substring i (n - i) pattern;

      # `{n}`, `{n,}` or `{n,m}` at `i`: null if it isn't one (then `{` is a
      # literal), `{ invalid = true; }` for counts RE2 rejects.
      repetition =
        i:
        let
          m = match "(\\{([0-9]+)(,([0-9]*))?}).*" (rest i);
          text = elemAt m 0;
          min = lib.toIntBase10 (elemAt m 1);
          open = elemAt m 2 != null && elemAt m 3 == "";
          max =
            if elemAt m 2 == null then
              min
            else if open then
              null
            else
              lib.toIntBase10 (elemAt m 3);
        in
        if m == null then
          null
        else if
          stringLength (elemAt m 1) > 4
          || stringLength (if elemAt m 3 == null then "" else elemAt m 3) > 4
          || min > 1000
          || (max != null && (max > 1000 || max < min))
        then
          { invalid = true; }
        else
          {
            invalid = false;
            next = i + stringLength text;
            out =
              if open then
                "{${toString min},}"
              else if max == min then
                "{${toString min}}"
              else
                "{${toString min},${toString max}}";
            copies = if max == null then min + 1 else lib.max max 1;
          };

      isQuantifier =
        i:
        lib.elem (at i) [
          "*"
          "+"
          "?"
        ]
        || (at i == "{" && repetition i != null);

      # `\x..` at `i` (the backslash): `{ code, next }` or null.
      hexEscape =
        i:
        let
          braced = match "\\\\x\\{([0-9A-Fa-f]{1,6})}.*" (rest i);
          plain = match "\\\\x([0-9A-Fa-f]{2}).*" (rest i);
          digits = if braced != null then builtins.head braced else builtins.head plain;
          code = lib.fromHexString digits;
        in
        if braced == null && plain == null then
          null
        else if code < 1 || code > 127 then
          null
        else
          {
            inherit code;
            next = i + (if braced != null then 4 + stringLength digits else 4);
          };

      # The escape at `i` (the backslash): `{ class, next, single }` (single:
      # one character, so usable as a range end), `{ anchor, next }`, or null.
      escape =
        i: inClass:
        let
          d = at (i + 1);
        in
        if d == null then
          null
        else if perlClasses ? ${d} then
          {
            class = perlClasses.${d};
            single = false;
            next = i + 2;
          }
        else if !inClass && d == "A" then
          {
            anchor = "^";
            next = i + 2;
          }
        else if !inClass && d == "z" then
          {
            anchor = "$";
            next = i + 2;
          }
        else if controlEscapes ? ${d} then
          {
            class = single controlEscapes.${d};
            single = true;
            next = i + 2;
          }
        else if d == "x" then
          bind (hexEscape i) (h: {
            class = single h.code;
            single = true;
            inherit (h) next;
          })
        # RE2 takes any other escaped ASCII punctuation (or space) literally.
        else if !isAlnum d then
          {
            class = single codeOf.${d};
            single = true;
            next = i + 2;
          }
        else
          null;

      # One character inside brackets: `{ code, next }`, or null.
      classChar =
        i:
        let
          c = at i;
        in
        if c == null then
          null
        else if c == "\\" then
          bind (escape i true) (
            e:
            if e.single then
              {
                code = builtins.head e.class.codes;
                inherit (e) next;
              }
            else
              null
          )
        else
          {
            code = codeOf.${c};
            next = i + 1;
          };

      # A bracket expression at `i` (the `[`): `{ class, next }` or null.
      parseBracket =
        i:
        let
          negated = at (i + 1) == "^";
          items =
            j: first: class:
            let
              c = at j;
              named = match "\\[:(\\^?)([a-z]+):].*" (rest j);
            in
            if c == null then
              null
            else if c == "]" && !first then
              {
                class = if negated then negate class else class;
                next = j + 1;
              }
            else if c == "[" && at (j + 1) == ":" && named != null then
              let
                name = elemAt named 1;
                posix = ascii posixClasses.${name};
              in
              if posixClasses ? ${name} then
                items (j + 4 + stringLength (elemAt named 0) + stringLength name) false (
                  union class (if elemAt named 0 == "^" then negate posix else posix)
                )
              else
                null
            else if c == "[" && at (j + 1) == ":" && lib.hasInfix ":]" (rest j) then
              null
            else if c == "\\" && perlClasses ? ${toString (at (j + 1))} then
              items (j + 2) false (union class perlClasses.${at (j + 1)})
            else
              bind (classChar j) (
                lo:
                if at lo.next == "-" && at (lo.next + 1) != "]" && at (lo.next + 1) != null then
                  bind (classChar (lo.next + 1)) (
                    hi:
                    if hi.code < lo.code then
                      null
                    else
                      items hi.next false (union class (ascii (lib.range lo.code hi.code)))
                  )
                else
                  items lo.next false (union class (single lo.code))
              );
        in
        items (if negated then i + 2 else i + 1) true (ascii [ ]);

      # One atom at `i`: `{ out, weight, next, quantifiable, anchor }` or null.
      atom =
        i: depth:
        let
          c = at i;
          fromClass =
            next: class:
            bind (emitClass class) (
              e:
              e
              // {
                inherit next;
                quantifiable = true;
                anchor = null;
              }
            );
          anchor = a: next: {
            out = a;
            weight = 1;
            inherit next;
            quantifiable = false;
            anchor = a;
          };
          group =
            j:
            bind (alternation j (depth + 1)) (
              r:
              if at r.next != ")" then
                null
              else
                {
                  out = "(${r.out})";
                  weight = r.weight + 1;
                  next = r.next + 1;
                  quantifiable = true;
                  anchor = null;
                }
            );
          named = match "(P?<)([A-Za-z0-9_]+)>.*" (rest (i + 2));
        in
        if c == "(" && at (i + 1) == "?" then
          if at (i + 2) == ":" then
            group (i + 3)
          else if named != null then
            group (i + 3 + stringLength (elemAt named 0) + stringLength (elemAt named 1))
          else
            null
        else if c == "(" then
          group (i + 1)
        else if c == "[" then
          bind (parseBracket i) (b: fromClass b.next b.class)
        else if c == "\\" then
          bind (escape i false) (e: if e ? anchor then anchor e.anchor e.next else fromClass e.next e.class)
        else if c == "." then
          fromClass (i + 1) anyButNewline
        else if c == "^" || c == "$" then
          anchor c (i + 1)
        else if isQuantifier i then
          null
        else
          fromClass (i + 1) (single codeOf.${c});

      # An atom followed by at most one quantifier (plus an ignored lazy `?`).
      quantified =
        i: depth:
        bind (atom i depth) (
          a:
          let
            j = a.next;
            c = at j;
            r = repetition j;
            q =
              if
                lib.elem c [
                  "*"
                  "+"
                  "?"
                ]
              then
                {
                  out = c;
                  next = j + 1;
                  copies = if c == "+" then 2 else 1;
                }
              else if c == "{" && r != null then
                if r.invalid then null else r
              else
                null;
            lazy = if at q.next == "?" then q.next + 1 else q.next;
          in
          if !(isQuantifier j) then
            a
          else if !a.quantifiable || q == null || isQuantifier lazy then
            null
          else
            a
            // {
              out = a.out + q.out;
              weight = a.weight * q.copies;
              next = lazy;
            }
        );

      # Atoms up to `|`, `)` or the end.
      sequence =
        i: depth:
        let
          go =
            i: acc:
            let
              c = at i;
            in
            if c == null || c == "|" || c == ")" then
              acc // { next = i; }
            else
              bind (quantified i depth) (
                q:
                go q.next {
                  out = acc.out + q.out;
                  weight = acc.weight + q.weight;
                  startAnchored = if acc.empty then q.anchor == "^" else acc.startAnchored;
                  endAnchored = q.anchor == "$";
                  empty = false;
                }
              );
        in
        go i {
          out = "";
          weight = 0;
          startAnchored = false;
          endAnchored = false;
          empty = true;
        };

      alternation =
        i: depth:
        bind (sequence i depth) (
          s:
          if at s.next == "|" then
            bind (alternation (s.next + 1) depth) (r: {
              out = "${s.out}|${r.out}";
              weight = s.weight + r.weight + 1;
              inherit (r) next;
              startAnchored = s.startAnchored && r.startAnchored;
              endAnchored = s.endAnchored && r.endAnchored;
            })
          else
            s
        );

      result = alternation 0 0;
    in
    if !utf8.isAscii pattern || n > 4096 then
      null
    else if result == null || result.next != n || result.weight > weightBudget then
      null
    else
      lib.optionalString (!result.startAnchored) ".*"
      + "(${result.out})"
      + lib.optionalString (!result.endAnchored) ".*";

  # A predicate for values `pattern` finds a match in, or null if it can't be
  # translated. Values over `inputLimit` bytes are accepted unchecked.
  matcher =
    pattern:
    bind (translate pattern) (ere: value: stringLength value > inputLimit || match ere value != null);
in
{
  inherit translate matcher inputLimit;
}
