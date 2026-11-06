// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Replay one of the suite's data files and fail with every case that came out
/// wrong, not just the first: one run then says whether the reader is off by a
/// detail or by a rule.
fn wpt_run(source : String, cases : Array[(String, String?)]) -> Unit raise {
  let failures : Array[String] = []
  for i, case in cases {
    let (input, expected) = case
    let label = "\{source}[\{i}] \{wpt_visible(input[:])}"
    match @moonmime.MediaType::parse(input[:]) {
      None =>
        if expected is Some(want) {
          failures.push("\{label}: refused, want \{want}")
        }
      Some(mt) =>
        match expected {
          None =>
            failures.push("\{label}: read \{wpt_serialize(mt)}, want a refusal")
          Some(want) => {
            let got = wpt_serialize(mt)
            if got != want {
              failures.push("\{label}: read \{got}, want \{want}")
            }
          }
        }
    }
  }
  if !failures.is_empty() {
    for failure in failures {
      println(failure)
    }
  }
  assert_eq(failures.length(), 0)
}

///|
/// The parser is measured in the standard's serialization, which is what the
/// data set's expected strings are written in: `type/subtype;name=value`, a
/// value quoted only when it is not a token. The library's own `to_string`
/// writes a space after each `;` — RFC 9110 allows it, the standard does not —
/// so the comparison spells the value out here instead of bending the library.
fn wpt_serialize(mt : @moonmime.MediaType) -> String {
  let out = StringBuilder()
  out.write_string(mt.essence)
  for pair in mt.params {
    out.write_char(';')
    out.write_string(pair.0)
    out.write_char('=')
    if pair.1.is_empty() || !wpt_is_token(pair.1[:]) {
      out.write_char('"')
      for i in 0..<pair.1.length() {
        let c = pair.1.at(i).to_int()
        if c == 0x22 || c == 0x5C {
          out.write_char('\\')
        }
        out.write_view(pair.1[i:i + 1])
      }
      out.write_char('"')
    } else {
      out.write_string(pair.1)
    }
  }
  out.to_string()
}

///|
fn wpt_is_token(s : StringView) -> Bool {
  for i in 0..<s.length() {
    match s.at(i).to_int() {
      '!'
      | '#'
      | '$'
      | '%'
      | '&'
      | '\''
      | '*'
      | '+'
      | '-'
      | '.'
      | '^'
      | '_'
      | '`'
      | '|'
      | '~'
      | '0'..<='9'
      | 'A'..<='Z'
      | 'a'..<='z' => ()
      _ => return false
    }
  }
  true
}

///|
/// A case as it would be read in a terminal: control characters are shown as
/// escapes, because a failure about an invisible byte otherwise reads as a
/// failure about nothing.
fn wpt_visible(s : StringView) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for i in 0..<s.length() {
    let c = s.at(i).to_int()
    if c < 0x20 || c == 0x7F {
      out.write_string("\\u{")
      out.write_string(c.to_string())
      out.write_char('}')
    } else {
      out.write_view(s[i:i + 1])
    }
  }
  out.write_char('"')
  out.to_string()
}

///|
/// The parse cases of the Web Platform Tests suite for MIME types, from
/// `mimesniff/mime-types/parsing.any.js`. A value is either read into a record
/// the standard would serialize back to the same string, or refused.
test "mime-types: the suite's own cases" {
  wpt_run("mime-types.json", wpt_mime_types_cases())
}

///|
/// The exhaustive half of the same suite: one case per byte in the places the
/// parser has to tell a token, a separator, and a value apart.
test "mime-types: the generated cases" {
  wpt_run("generated-mime-types.json", wpt_generated_mime_types_cases())
}
