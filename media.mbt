// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A media type: `text/plain; charset=utf-8`.
///
/// `essence` is the lowercased `type/subtype`; `params` keeps the parameters in
/// order, names lowercased and quoted values unquoted. A malformed parameter is
/// dropped rather than guessed at.
pub(all) struct MediaType {
  essence : String
  params : Array[(String, String)]
} derive(Eq, Debug)

///|
pub extend MediaType with Eq::{equal, not_equal}

///|
pub extend MediaType with Debug::{to_repr}

///|
/// Parse a header value into a media type. Lenient: anything that is not a
/// parameter is left out, so an empty or foreign value yields an empty essence
/// rather than an error.
pub fn media_type(s : StringView) -> MediaType {
  let semi = index_char(s, 0x3B, 0)
  let head = if semi < 0 { s } else { s[0:semi] }
  let params : Array[(String, String)] = if semi < 0 {
    []
  } else {
    parse_params(s[semi + 1:])
  }
  { essence: trim(head).to_lower(), params, }
}

///|
/// The type half: `text` in `text/plain`.
pub fn MediaType::type_(self : MediaType) -> String {
  match index_char(self.essence[:], 0x2F, 0) {
    -1 => self.essence
    at => self.essence[0:at].to_owned()
  }
}

///|
/// The subtype half: `plain` in `text/plain`, empty when there is no slash.
pub fn MediaType::subtype(self : MediaType) -> String {
  match index_char(self.essence[:], 0x2F, 0) {
    -1 => ""
    at => self.essence[at + 1:].to_owned()
  }
}

///|
/// A parameter by lowercased name, quoted or bare.
pub fn MediaType::param(self : MediaType, name : StringView) -> String? {
  for pair in self.params {
    if pair.0[:] == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Back to a header value. A value that is not a token goes out quoted, which
/// keeps a boundary with spaces or quotes in one piece.
pub impl Show for MediaType with fn to_string(self) {
  let out = StringBuilder()
  out.write_string(self.essence)
  for pair in self.params {
    out.write_char(';')
    out.write_char(' ')
    out.write_string(pair.0)
    out.write_char('=')
    if is_token(pair.1[:]) {
      out.write_string(pair.1)
    } else {
      out.write_char('"')
      for i in 0..<pair.1.length() {
        let c = pair.1[i].to_int()
        if c == 0x22 || c == 0x5C {
          out.write_char('\\')
        }
        out.write_view(pair.1[i:i + 1])
      }
      out.write_char('"')
    }
  }
  out.to_string()
}

///|
pub extend MediaType with Show::{to_string, output}

///|
/// `name=value; ...` from the part of a header after its first `;`.
///
/// A name is a token; a value is a token or a quoted string. A segment with no
/// `=` is dropped.
fn parse_params(s : StringView) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let n = s.length()
  let mut i = 0
  while i < n {
    while i < n && (is_space(s.at(i).to_int()) || s.at(i).to_int() == 0x3B) {
      i += 1
    }
    let name_start = i
    while i < n &&
          s.at(i).to_int() != 0x3D &&
          s.at(i).to_int() != 0x3B &&
          !is_space(s.at(i).to_int()) {
      i += 1
    }
    let mut name_end = i
    while name_end > name_start && is_space(s.at(name_end - 1).to_int()) {
      name_end -= 1
    }
    while i < n && is_space(s.at(i).to_int()) {
      i += 1
    }
    guard i < n && s.at(i).to_int() == 0x3D else {
      while i < n && s.at(i).to_int() != 0x3B {
        i += 1
      }
      continue
    }
    let name = s[name_start:name_end].to_owned()
    i += 1
    while i < n && is_space(s.at(i).to_int()) {
      i += 1
    }
    if i < n && s.at(i).to_int() == 0x22 {
      i += 1
      let value = StringBuilder()
      while i < n && s.at(i).to_int() != 0x22 {
        if s.at(i).to_int() == 0x5C && i + 1 < n {
          i += 1
        }
        value.write_view(s[i:i + 1])
        i += 1
      }
      if i < n {
        i += 1
      }
      out.push((name.to_lower(), value.to_string()))
    } else {
      let value_start = i
      while i < n && s.at(i).to_int() != 0x3B {
        i += 1
      }
      out.push((name.to_lower(), trim(s[value_start:i])))
    }
  }
  out
}

///|
/// Whether a value can stand bare in a parameter.
fn is_token(s : StringView) -> Bool {
  if s.is_empty() {
    return false
  }
  for i in 0..<s.length() {
    if !is_tchar(s.at(i).to_int()) {
      return false
    }
  }
  true
}

///|
/// An RFC 7230 token character.
fn is_tchar(c : Int32) -> Bool {
  match c {
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
    | 'a'..<='z' => true
    _ => false
  }
}

///|
fn trim(s : StringView) -> String {
  let mut from = 0
  let mut to = s.length()
  while from < to && is_space(s.at(from).to_int()) {
    from += 1
  }
  while to > from && is_space(s.at(to - 1).to_int()) {
    to -= 1
  }
  s[from:to].to_owned()
}

///|
fn is_space(c : Int32) -> Bool {
  c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0A
}

///|
fn index_char(s : StringView, needle : Int32, from : Int32) -> Int32 {
  for i = from; i < s.length(); i = i + 1 {
    if s.at(i).to_int() == needle {
      return i
    }
  }
  -1
}
