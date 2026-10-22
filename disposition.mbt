// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A parsed `Content-Disposition` header (RFC 6266).
///
/// `kind` is the lowercased disposition type — `inline`, `attachment`,
/// `form-data` — and `params` the rest, names lowercased and quoted values
/// unquoted.
pub(all) struct Disposition {
  kind : String
  params : Array[(String, String)]
} derive(Eq, Debug)

///|
pub extend Disposition with Eq::{equal, not_equal}

///|
pub extend Disposition with Debug::{to_repr}

///|
/// Parse a header value. Lenient, like [`media_type`].
pub fn Disposition::parse(s : StringView) -> Disposition {
  let semi = index_char(s, 0x3B, 0)
  let head = if semi < 0 { s } else { s[0:semi] }
  let params : Array[(String, String)] = if semi < 0 {
    []
  } else {
    parse_params(s[semi + 1:])
  }
  { kind: trim(head).to_lower(), params, }
}

///|
/// A parameter by lowercased name.
pub fn Disposition::param(self : Disposition, name : StringView) -> String? {
  for pair in self.params {
    if pair.0[:] == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// The filename the disposition names, `filename*` first (RFC 6266 §4.3).
///
/// A `filename*` that is not UTF-8 falls back to the plain `filename`.
pub fn Disposition::filename(self : Disposition) -> String? {
  match self.param("filename*") {
    Some(ext) =>
      match decode_ext(ext) {
        Some(name) => Some(name)
        None => self.param("filename")
      }
    None => self.param("filename")
  }
}

///|
/// The `Content-Disposition` value naming `filename` (RFC 6266).
///
/// A name that is plain ASCII goes out quoted; anything else — a space is not
/// enough, but an accent, a quote, a newline, a byte outside ASCII — goes out
/// as `filename*`, the only form that carries them and the only one a name
/// cannot break out of.
///
/// `inline` asks the browser to show the content rather than save it.
pub fn content_disposition(
  filename : StringView,
  inline~ : Bool = false,
) -> String {
  let kind = if inline { "inline" } else { "attachment" }
  if quoted_safe(filename) {
    kind + "; filename=\"" + filename.to_owned() + "\""
  } else {
    kind + "; filename*=utf-8''" + @percent.encode(filename)
  }
}

///|
/// The `charset'lang'value` of a `filename*`, decoded when the charset is UTF-8.
///
/// Anything else is `None`, and the caller falls back to `filename`: the value
/// is not UTF-8 text and must not be shown as if it were.
fn decode_ext(ext : String) -> String? {
  let first = index_char(ext[:], 0x27, 0)
  if first < 0 {
    return None
  }
  let rest = ext[first + 1:]
  let second = index_char(rest, 0x27, 0)
  if second < 0 {
    return None
  }
  let charset = ext[0:first]
  let value = rest[second + 1:]
  if charset.to_lower() != "utf-8" {
    return None
  }
  Some(@percent.decode_lossy(value))
}

///|
/// Whether a filename can stand inside a quoted `filename` as it is.
fn quoted_safe(s : StringView) -> Bool {
  for i in 0..<s.length() {
    let c = s.at(i).to_int()
    if c < 0x20 || c > 0x7E || c == 0x22 || c == 0x5C {
      return false
    }
  }
  true
}
