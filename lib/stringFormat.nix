# The string `format`s Kubernetes validates in CRD schemas, as predicates.
#
# The apiextensions-apiserver keeps a fixed list of formats
# (`pkg/apiserver/validation/formats.go`) and checks values with
# kube-openapi's `strfmt` registry. Each predicate here mirrors its Go
# definition (the regexes and checksums in `strfmt` and its vendored
# `govalidator`); formats that need a parser this can't mirror faithfully
# (`uri`, `email`, `ipv4`, `ipv6`, `cidr`) aren't checked, nor is `password`,
# which admits any string.
#
# Values over `inputLimit` bytes that would need an unbounded regex match are
# accepted unchecked: libstdc++'s matcher overflows the stack on long input.
{ lib, utf8 }:
let
  inherit (builtins)
    elemAt
    match
    stringLength
    substring
    ;

  inputLimit = 8192;
  bounded = f: s: stringLength s > inputLimit || f s;
  matches = regex: s: match regex s != null;

  # Characters without a Nix string escape.
  formFeed = builtins.fromJSON ''"\f"'';
  # Go's \s: [\t\n\f\r ].
  goSpace = "\t\n${formFeed}\r ";

  hex = "[0-9a-fA-F]";
  digitValue = c: lib.strings.charToInt c - 48;
  digits = s: map digitValue (lib.stringToCharacters s);
  removeMatches = regex: s: lib.concatStrings (lib.filter lib.isString (builtins.split regex s));

  # Go's time.Parse("2006-01-02"): fixed-width fields, a day that exists.
  isLeap = y: lib.mod y 4 == 0 && (lib.mod y 100 != 0 || lib.mod y 400 == 0);
  daysIn =
    y: m:
    if m == 2 then
      (if isLeap y then 29 else 28)
    else if
      lib.elem m [
        4
        6
        9
        11
      ]
    then
      30
    else
      31;
  date =
    s:
    let
      m = match "([0-9]{4})-([0-9]{2})-([0-9]{2})" s;
      year = lib.toIntBase10 (elemAt m 0);
      month = lib.toIntBase10 (elemAt m 1);
      day = lib.toIntBase10 (elemAt m 2);
    in
    m != null && month >= 1 && month <= 12 && day >= 1 && day <= daysIn year month;

  # strfmt.IsDateTime: split the lowercased value on "t", a date before the
  # first, and `hh:mm:ss[.frac](z|±hh:mm)` (hours to 23, minutes and seconds
  # to 59) after it.
  dateTime =
    s:
    let
      parts = lib.splitString "t" (lib.toLower s);
      time = match "([0-9]{2}):([0-9]{2}):([0-9]{2})([^\n][0-9]+)?(z|[+-][0-9]{2}:[0-9]{2})" (
        elemAt parts 1
      );
    in
    stringLength s >= 4
    && builtins.length parts >= 2
    && date (builtins.head parts)
    && time != null
    && elemAt time 0 <= "23"
    && elemAt time 1 <= "59"
    && elemAt time 2 <= "59";

  # strfmt.ParseDuration: Go's time.ParseDuration, or else any number followed
  # by a known unit (Scala style) anywhere in the string.
  duration =
    s:
    let
      mu = "(µ|μ)";
      component = "([0-9]+([.][0-9]*)?|[.][0-9]+)(ns|us|${mu}s|ms|s|m|h)";
      goDuration = matches "[-+]?(0|(${component})+)" s;

      units = [
        [
          "ns"
          "nano"
        ]
        [
          "us"
          "µs"
          "micro"
        ]
        [
          "ms"
          "milli"
        ]
        [
          "s"
          "sec"
        ]
        [
          "m"
          "min"
        ]
        [
          "h"
          "hr"
          "hour"
        ]
        [
          "d"
          "day"
        ]
        [
          "w"
          "wk"
          "week"
        ]
      ];
      knownUnit =
        unit:
        lib.any (variants: lib.any (v: v == unit) variants || lib.hasPrefix (lib.last variants) unit) units;
      # strconv.Atoi fails past int64, failing the whole parse.
      overflows =
        number:
        let
          n = builtins.head (match "0*([0-9]*)" number);
        in
        stringLength n > 19 || (stringLength n == 19 && n > "9223372036854775807");
      found = lib.filter lib.isList (builtins.split "([0-9]+)[${goSpace}]*(([A-Za-z]|µ)+)" s);
      scala =
        !(lib.any (m: overflows (elemAt m 0)) found)
        && lib.any (m: knownUnit (lib.toLower (elemAt m 1))) found;
      # time.ParseDuration fails past 2^63 ns. Anything it takes but the
      # fallback doesn't is `0` or uses the Greek mu (μs), where 12 digits
      # stay in range.
      digitRuns = map builtins.head (lib.filter lib.isList (builtins.split "([0-9]+)" s));
      inRange = lib.all (run: stringLength run <= 12) digitRuns;
    in
    scala || (goDuration && inRange);

  # strfmt.HostnamePattern, whose \p{S} and \p{L} are, within ASCII, the
  # symbols $+<=>^`|~ and the letters; non-ASCII names aren't checked. At
  # most 255 bytes, labels at most 63.
  hostnameChar = "[a-zA-Z0-9$+<=>^`|~]";
  hostnameInner = "[a-zA-Z0-9$+<=>^`|~-]";
  hostname =
    s:
    stringLength s <= 255
    && (
      !utf8.isAscii s
      ||
        matches "${hostnameChar}((-?${hostnameChar}{0,62})?)|(${hostnameChar}((${hostnameInner}{0,61}${hostnameChar})?)([.])){1,}([a-zA-Z]){2,63}" s
        && lib.all (label: stringLength label <= 63) (lib.splitString "." s)
    );

  # base64 (the standard alphabet, padded), as govalidator.IsBase64; also
  # empty and with line breaks, which Go's encoding/json accepts for the
  # `[]byte` fields of built-in kinds. No regex, so any length works.
  base64Alphabet = lib.stringToCharacters "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  noBase64 = map (_: "") base64Alphabet;
  byte =
    s:
    let
      t = builtins.replaceStrings [ "\r" "\n" ] [ "" "" ] s;
      len = stringLength t;
      padding =
        if lib.hasSuffix "==" t then
          2
        else if lib.hasSuffix "=" t then
          1
        else
          0;
    in
    t == ""
    || (
      lib.mod len 4 == 0
      && builtins.replaceStrings base64Alphabet noBase64 (substring 0 (len - padding) t) == ""
    );

  # net.ParseMAC: 6, 8 or 20 octets, as colon- or dash-separated pairs or
  # dot-separated quads.
  mac =
    s:
    let
      separated = sep: "${hex}{2}((${sep}${hex}{2}){5}|(${sep}${hex}{2}){7}|(${sep}${hex}{2}){19})";
    in
    stringLength s <= 59
    && (
      matches (separated ":") s
      || matches (separated "-") s
      || matches "${hex}{4}(([.]${hex}{4}){2}|([.]${hex}{4}){3}|([.]${hex}{4}){9})" s
    );

  # govalidator.IsISBN10/IsISBN13: whitespace and dashes dropped, then a
  # checksum.
  isbnDigits = removeMatches "[${goSpace}-]+";
  isbn10 =
    s:
    let
      d = isbnDigits s;
      values = digits (substring 0 9 d);
      check = if substring 9 1 d == "X" then 10 else digitValue (substring 9 1 d);
      sum = lib.foldl' builtins.add 0 (lib.imap1 (i: v: i * v) values) + 10 * check;
    in
    matches "[0-9]{9}X|[0-9]{10}" d && lib.mod sum 11 == 0;
  isbn13 =
    s:
    let
      d = isbnDigits s;
      values = digits d;
      sum = lib.foldl' builtins.add 0 (
        lib.imap0 (i: v: if lib.mod i 2 == 0 then v else 3 * v) (lib.take 12 values)
      );
    in
    matches "[0-9]{13}" d && lib.last values == lib.mod (10 - lib.mod sum 10) 10;

  # govalidator.IsCreditCard: non-digits dropped, a known issuer's number,
  # then the Luhn checksum.
  creditCard =
    s:
    let
      d = removeMatches "[^0-9]+" s;
      luhn = lib.imap0 (
        i: v: if lib.mod i 2 == 1 then (if v * 2 >= 10 then lib.mod (v * 2) 10 + 1 else v * 2) else v
      ) (lib.reverseList (digits d));
    in
    matches "4[0-9]{12}([0-9]{3})?|5[1-5][0-9]{14}|6(011|5[0-9][0-9])[0-9]{12}|3[47][0-9]{13}|3(0[0-5]|[68][0-9])[0-9]{11}|(2131|1800|35[0-9]{3})[0-9]{11}" d
    && lib.mod (lib.foldl' builtins.add 0 luhn) 10 == 0;

  rgbValue = "(0|[1-9][0-9]?|1[0-9][0-9]?|2[0-4][0-9]|25[0-5])";
  rgbSpace = "[${goSpace}]*";

  uuid =
    version: variant:
    matches "${hex}{8}-?${hex}{4}-?${version}${hex}{3}-?${variant}${hex}{3}-?${hex}{12}";

  # kube-openapi's Kubernetes extensions: a DNS-1123 label without uppercase,
  # and dot-separated ones (with no per-label limit).
  shortName = "[a-z0-9]([-a-z0-9]*[a-z0-9])?";

  # Keyed by normalized name (Kubernetes drops dashes: `date-time` is
  # `datetime`).
  formats = {
    bsonobjectid = s: stringLength s == 24 && matches "${hex}{24}" s;
    byte = byte;
    date = s: stringLength s == 10 && date s;
    datetime = bounded dateTime;
    duration = bounded duration;
    hostname = hostname;
    mac = mac;
    uuid = s: stringLength s <= 36 && uuid hex hex s;
    uuid3 = s: stringLength s <= 36 && uuid "3" hex s;
    uuid4 = s: stringLength s <= 36 && uuid "4" "[89abAB]" s;
    uuid5 = s: stringLength s <= 36 && uuid "5" "[89abAB]" s;
    isbn = bounded (s: isbn10 s || isbn13 s);
    isbn10 = bounded isbn10;
    isbn13 = bounded isbn13;
    creditcard = bounded creditCard;
    ssn = s: stringLength s == 11 && matches "[0-9]{3}[- ]?[0-9]{2}[- ]?[0-9]{4}" s;
    hexcolor = s: stringLength s <= 7 && matches "#?(${hex}{3}|${hex}{6})" s;
    rgbcolor = bounded (
      matches "rgb[(]${rgbSpace}${rgbValue}${rgbSpace},${rgbSpace}${rgbValue}${rgbSpace},${rgbSpace}${rgbValue}${rgbSpace}[)]"
    );
    k8sshortname = s: stringLength s <= 63 && matches shortName s;
    k8slongname = s: stringLength s <= 253 && matches "${shortName}([.]${shortName})*" s;
  };
in
{
  inherit inputLimit;

  # The formats checked, by normalized name.
  checked = builtins.attrNames formats;

  # A predicate for strings in `format`, or null if it isn't checked.
  check = format: formats.${builtins.replaceStrings [ "-" ] [ "" ] format} or null;
}
