# Unit tests for lib/stringFormat.nix: the string `format`s Kubernetes
# validates in CRDs, each mirroring kube-openapi's Go definition.
{ lib, catenix, ... }:
let
  inherit (catenix.stringFormat) check;

  valid = format: map (check format);
  allValid = format: values: lib.all (check format) values;
  noneValid = format: values: !(lib.any (check format) values);
in
{
  # Kubernetes normalizes names by dropping dashes.
  testNamesNormalizeDashes = {
    expr = map (f: check f != null) [
      "date-time"
      "datetime"
      "k8s-short-name"
      "k8sshortname"
      "u-u-i-d"
    ];
    expected = [
      true
      true
      true
      true
      true
    ];
  };

  # Unknown formats (and `password`, which admits anything, and the formats
  # this unit can't mirror) aren't checked: null.
  testUncheckedFormats = {
    expr = map check [
      "password"
      "int-or-string"
      "int32"
      "made-up"
      "uri"
      "email"
      "ipv4"
      "ipv6"
      "cidr"
    ];
    expected = lib.genList (_: null) 9;
  };

  testByte = {
    expr = {
      valid = allValid "byte" [
        "aGVsbG8="
        "aGVsbA=="
        "aGVs"
        "a+/9"
        # Accepted for built-in kinds' []byte fields, which Go decodes with
        # encoding/json: empty, or with line breaks.
        ""
        "aGVs\nbG8="
      ];
      invalid = noneValid "byte" [
        "aGVsbG8"
        "aGVsbG8=="
        "a=Vs"
        "a==="
        "aGV-"
        "aGV_"
        "not base64!"
      ];
    };
    expected = {
      valid = true;
      invalid = true;
    };
  };

  testByteLong = {
    expr = check "byte" (lib.concatStrings (lib.genList (_: "QUJD") 20000));
    expected = true;
  };

  testDate = {
    expr = {
      valid = allValid "date" [
        "2024-02-29"
        "2000-02-29"
        "1999-12-31"
        "0000-01-01"
      ];
      invalid = noneValid "date" [
        "2023-02-29"
        "1900-02-29"
        "2024-13-01"
        "2024-00-10"
        "2024-04-31"
        "2024-01-00"
        "2024-1-01"
        "24-01-01"
        "2024-01-01T00:00:00Z"
        ""
      ];
    };
    expected = {
      valid = true;
      invalid = true;
    };
  };

  testDateTime = {
    expr = {
      valid = allValid "date-time" [
        "2024-01-02T03:04:05Z"
        "2024-01-02T03:04:05.123456Z"
        "2024-01-02T03:04:05+01:00"
        "2024-01-02t03:04:05z"
        "2024-01-02T23:59:59,5-12:30"
      ];
      invalid = noneValid "date-time" [
        "2024-01-02"
        "2024-01-02T24:00:00Z"
        "2024-01-02T03:60:00Z"
        "2024-01-02T03:04:60Z"
        "2024-01-02T03:04:05"
        "2024-01-02T03:04:05+0100"
        "2024-02-30T03:04:05Z"
        "2024-01-02 03:04:05Z"
        "now"
      ];
    };
    expected = {
      valid = true;
      invalid = true;
    };
  };

  testUuid = {
    expr = {
      uuid = valid "uuid" [
        "123e4567-e89b-12d3-a456-426614174000"
        "123E4567E89B12D3A456426614174000"
        "123e4567-e89b-12d3-a456-42661417400"
        "g23e4567-e89b-12d3-a456-426614174000"
      ];
      uuid3 = valid "uuid3" [
        "a3bb189e-8bf9-3888-9912-ace4e6543002"
        "a3bb189e-8bf9-4888-9912-ace4e6543002"
      ];
      uuid4 = valid "uuid4" [
        "f47ac10b-58cc-4372-a567-0e02b2c3d479"
        "f47ac10b-58cc-4372-c567-0e02b2c3d479"
      ];
      uuid5 = valid "uuid5" [
        "886313e1-3b8a-5372-9b90-0c9aee199e5d"
        "886313e1-3b8a-4372-9b90-0c9aee199e5d"
      ];
    };
    expected = {
      uuid = [
        true
        true
        false
        false
      ];
      uuid3 = [
        true
        false
      ];
      uuid4 = [
        true
        false
      ];
      uuid5 = [
        true
        false
      ];
    };
  };

  testBsonObjectId = {
    expr = valid "bsonobjectid" [
      "507f1f77bcf86cd799439011"
      "507F1F77BCF86CD799439011"
      "507f1f77bcf86cd79943901"
      "507f1f77bcf86cd79943901z"
    ];
    expected = [
      true
      true
      false
      false
    ];
  };

  testDuration = {
    expr = {
      valid = allValid "duration" [
        "0"
        "1h30m"
        "1.5h"
        ".5s"
        "-5s"
        "300ms"
        "1µs"
        "1μs"
        "1us"
        # the Scala-style fallback: a number and a unit anywhere
        "3 days"
        "5 seconds"
        "2 hours and more"
        "1w"
        "10 MINUTES"
      ];
      invalid = noneValid "duration" [
        ""
        "1"
        "h"
        "1x"
        "forever"
        "1.h2"
        "99999999999999999999s"
      ];
    };
    expected = {
      valid = true;
      invalid = true;
    };
  };

  testHostname = {
    expr = {
      valid = allValid "hostname" [
        "localhost"
        "example.com"
        "a-b.example.co"
        "x"
        # non-ASCII names aren't checked
        "bücher.example"
      ];
      invalid = noneValid "hostname" [
        "-example.com"
        "example-.com"
        "exa mple.com"
        "example.c"
        "example.123"
        (lib.concatStrings (lib.genList (_: "a") 64) + ".com")
        ""
      ];
    };
    expected = {
      valid = true;
      invalid = true;
    };
  };

  testMac = {
    expr = {
      valid = allValid "mac" [
        "01:23:45:67:89:ab"
        "01-23-45-67-89-AB"
        "01:23:45:67:89:ab:cd:ef"
        "0123.4567.89ab"
        "0123.4567.89ab.cdef"
        "00:00:00:00:fe:80:00:00:00:00:00:00:02:00:5e:10:00:00:00:01"
      ];
      invalid = noneValid "mac" [
        "01:23:45:67:89"
        "01:23:45-67:89:ab"
        "0123.4567"
        "01:23:45:67:89:ag"
        "01:23:45:67:89:ab:cd"
      ];
    };
    expected = {
      valid = true;
      invalid = true;
    };
  };

  testIsbn = {
    expr = {
      isbn10 = valid "isbn10" [
        "0321751043"
        "0-321-75104-3"
        "080442957X"
        "0321751044"
      ];
      isbn13 = valid "isbn13" [
        "978-0321751041"
        "9780321751041"
        "9780321751042"
      ];
      isbn = valid "isbn" [
        "0321751043"
        "978 0321751041"
        "123"
      ];
    };
    expected = {
      isbn10 = [
        true
        true
        true
        false
      ];
      isbn13 = [
        true
        true
        false
      ];
      isbn = [
        true
        true
        false
      ];
    };
  };

  testCreditCard = {
    expr = valid "creditcard" [
      "4111111111111111"
      "4111-1111-1111-1111"
      "5500 0000 0000 0004"
      "4111111111111112"
      "1234"
    ];
    expected = [
      true
      true
      true
      false
      false
    ];
  };

  testSsn = {
    expr = valid "ssn" [
      "123-45-6789"
      "123 45 6789"
      "123456789"
      "123-45-678"
    ];
    expected = [
      true
      true
      false
      false
    ];
  };

  testColors = {
    expr = {
      hex = valid "hexcolor" [
        "#fff"
        "FFFFFF"
        "#ffff"
        "#ggg"
      ];
      rgb = valid "rgbcolor" [
        "rgb(255,0,10)"
        "rgb( 1 , 2 , 3 )"
        "rgb(256,0,0)"
        "rgb(01,0,0)"
      ];
    };
    expected = {
      hex = [
        true
        true
        false
        false
      ];
      rgb = [
        true
        true
        false
        false
      ];
    };
  };

  testKubernetesNames = {
    expr = {
      short = valid "k8s-short-name" [
        "my-app"
        "a"
        "My-app"
        "-a"
        "a.b"
        (lib.concatStrings (lib.genList (_: "a") 63))
        (lib.concatStrings (lib.genList (_: "a") 64))
      ];
      long = valid "k8s-long-name" [
        "a.b-c.d"
        (lib.concatStrings (lib.genList (_: "a") 100))
        "a..b"
        "A.b"
        (lib.concatStringsSep "." (lib.genList (_: "abc") 64))
      ];
    };
    expected = {
      short = [
        true
        true
        false
        false
        false
        true
        false
      ];
      long = [
        true
        true
        false
        false
        false
      ];
    };
  };
}
