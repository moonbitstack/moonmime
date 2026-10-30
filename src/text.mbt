// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn code(c : Char) -> Int32 {
  c.to_int()
}

///|
fn byte_code(b : Byte) -> Int32 {
  b.to_int()
}

///|
fn lower(s : StringView) -> String {
  s.to_owned().to_lower()
}

///|
/// The character for one hex digit, upper-cased as RFC 2047's examples write it.
fn hex_digit(n : Int32) -> Char {
  if n < 10 {
    (code('0') + n).unsafe_to_char()
  } else {
    (code('A') + n - 10).unsafe_to_char()
  }
}

///|
/// WSP, the two characters RFC 5322 §2.2.2 allows as folding whitespace.
fn is_wsp(c : Char) -> Bool {
  c == ' ' || c == '\t'
}

///|
fn is_alpha(c : Char) -> Bool {
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

///|
fn is_digit(c : Char) -> Bool {
  c >= '0' && c <= '9'
}

///|
/// Whether every character is printable US-ASCII, which decides between writing
/// a header value as it stands and writing it as encoded words.
fn is_ascii_printable(s : StringView) -> Bool {
  s.all(c => code(c) >= 32 && code(c) <= 126)
}
