// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A media type: `text/plain; charset=utf-8`.
///
/// `essence` is the lowercased `type/subtype`; `params` keeps the parameters in
/// order, names lowercased and quoted values unquoted. A malformed parameter is
/// dropped rather than guessed at.
#derive(Eq, Debug)
pub(all) struct MediaType {
  essence : String
  params : Array[(String, String)]
}

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
/// Parse a header value the way the MIME Sniffing standard reads one, and
/// refuse the rest: `None` when the value is not a `type/subtype` of tokens.
///
/// Two readers, two jobs. `media_type` above takes whatever a server sent and
/// keeps what it can; this one answers "is this a media type at all", which is
/// the question worth asking when a value decides what a file is. A parameter
/// whose name is not a token, or whose value cannot be written into a quoted
/// string, is dropped; the first of two with the same name wins. Both are the
/// standard's readings.
///
/// ```mbt check
/// test {
///   let mt = @moonmime.MediaType::parse("Text/HTML; charset=\"utf-8\"").unwrap()
///   inspect(mt.essence, content="text/html")
///   inspect(mt.param("charset").unwrap_or(""), content="utf-8")
///   inspect(
///     @moonmime.MediaType::parse("text/html, text/plain") is None,
///     content="true",
///   )
/// }
/// ```
pub fn MediaType::parse(s : StringView) -> MediaType? {
  let text = trim(s)
  let n = text.length()
  let mut i = 0
  let type_start = i
  while i < n && text.at(i).to_int() != 0x2F {
    i += 1
  }
  let kind = text[type_start:i]
  guard i < n && is_token(kind) else { return None }
  i += 1
  let subtype_start = i
  while i < n && text.at(i).to_int() != 0x3B {
    i += 1
  }
  let subtype = trim_end(text[subtype_start:i])
  guard is_token(subtype) else { return None }
  let params : Array[(String, String)] = []
  while i < n {
    i += 1
    while i < n && is_space(text.at(i).to_int()) {
      i += 1
    }
    let name_start = i
    while i < n && text.at(i).to_int() != 0x3B && text.at(i).to_int() != 0x3D {
      i += 1
    }
    let name = text[name_start:i].to_lower().to_owned()
    if i < n {
      // A `;` where the `=` should be: this parameter has no value at all.
      if text.at(i).to_int() == 0x3B {
        continue
      }
      i += 1
    }
    // The name ends the value: `text/html;charset` is still a media type.
    if i >= n {
      break
    }
    let value : String? = if text.at(i).to_int() == 0x22 {
      let (quoted, after) = collect_quoted(text, i)
      i = after
      // Junk between the closing quote and the next `;` is not a parameter.
      while i < n && text.at(i).to_int() != 0x3B {
        i += 1
      }
      Some(quoted)
    } else {
      let value_start = i
      while i < n && text.at(i).to_int() != 0x3B {
        i += 1
      }
      let bare = trim_end(text[value_start:i])
      if bare.is_empty() {
        None
      } else {
        Some(bare.to_owned())
      }
    }
    match value {
      Some(v) =>
        if !name.is_empty() &&
          is_token(name[:]) &&
          is_quoted_string_token(v[:]) &&
          !has_name(params, name) {
          params.push((name, v))
        }
      None => ()
    }
  }
  let out = StringBuilder()
  out.write_string(kind.to_lower().to_owned())
  out.write_char('/')
  out.write_string(subtype.to_lower().to_owned())
  Some({ essence: out.to_string(), params, })
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
fn trim_end(s : StringView) -> StringView {
  let mut to = s.length()
  while to > 0 && is_space(s.at(to - 1).to_int()) {
    to -= 1
  }
  s[0:to]
}

///|
/// A quoted string, read from the opening quote at `from`, with its escapes
/// resolved and the quotes gone. Also answers where reading stopped, so the
/// caller can skip whatever followed the closing quote.
fn collect_quoted(s : StringView, from : Int32) -> (String, Int32) {
  let n = s.length()
  let out = StringBuilder()
  let mut i = from + 1
  while i < n {
    let c = s.at(i).to_int()
    if c == 0x22 {
      return (out.to_string(), i + 1)
    }
    if c == 0x5C {
      // A backslash with nothing behind it is part of the value, not an escape.
      if i + 1 >= n {
        out.write_char('\\')
        return (out.to_string(), n)
      }
      out.write_view(s[i + 1:i + 2])
      i += 2
      continue
    }
    out.write_view(s[i:i + 1])
    i += 1
  }
  (out.to_string(), n)
}

///|
fn has_name(params : Array[(String, String)], name : String) -> Bool {
  for pair in params {
    if pair.0 == name {
      return true
    }
  }
  false
}

///|
/// The characters a quoted-string may carry: TAB, printable ASCII, and the
/// upper half of Latin-1. A value outside them cannot be written back out.
fn is_quoted_string_token(s : StringView) -> Bool {
  for i in 0..<s.length() {
    let c = s.at(i).to_int()
    if c != 0x09 && !(c >= 0x20 && c <= 0x7E) && !(c >= 0x80 && c <= 0xFF) {
      return false
    }
  }
  true
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
