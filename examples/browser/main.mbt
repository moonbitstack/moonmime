// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The demo's raw multipart text, as bytes.
fn bytes_of(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < s.length(); i = i + 1 {
    out.push((s[i].to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A string as a JSON value, quotes and backslashes escaped.
fn jstr(s : String) -> String {
  let b = StringBuilder()
  b.write_char('"')
  for i = 0; i < s.length(); i = i + 1 {
    let c = s[i]
    if c == '"' {
      b.write_string("\\\"")
    } else if c == '\\' {
      b.write_string("\\\\")
    } else if c == '\n' {
      b.write_string("\\n")
    } else if c == '\r' {
      b.write_string("\\r")
    } else if c == '\t' {
      b.write_string("\\t")
    } else {
      b.write_view(s[i:i + 1])
    }
  }
  b.write_char('"')
  b.to_string()
}

///|
/// The media type a filename's extension implies.
pub fn browser_guess_type(name : String) -> String {
  @moonmime.guess_type(name[:])
}

///|
/// The common extension for a media type, or empty when unknown.
pub fn browser_guess_extension(value : String) -> String {
  match @moonmime.guess_extension(value[:]) {
    Some(e) => e
    None => ""
  }
}

///|
/// A `Content-Type` header, parsed: its essence, type, subtype, and the value
/// it writes back as.
pub fn browser_media_type(header : String) -> String {
  let mt = @moonmime.media_type(header[:])
  let essence = if mt.subtype() == "" {
    mt.type_()
  } else {
    mt.type_() + "/" + mt.subtype()
  }
  "{\"essence\":" +
  jstr(essence) +
  ",\"type\":" +
  jstr(mt.type_()) +
  ",\"subtype\":" +
  jstr(mt.subtype()) +
  ",\"string\":" +
  jstr(mt.to_string()) +
  "}"
}

///|
/// A `Content-Disposition` header that names `filename`; non-ASCII goes out as
/// `filename*` (RFC 5987).
pub fn browser_content_disposition(filename : String, inline : Bool) -> String {
  @moonmime.content_disposition(filename[:], inline~)
}

///|
/// Split a multipart body into its parts and report each part's
/// `Content-Disposition` (name, filename), content type, size, and body text.
pub fn browser_multipart(body : String, boundary : String) -> String {
  try {
    let parts = @moonmime.multipart(bytes_of(body)[:], boundary[:])
    let b = StringBuilder()
    b.write_char('[')
    for i = 0; i < parts.length(); i = i + 1 {
      if i > 0 {
        b.write_char(',')
      }
      let p = parts[i]
      let d = p.disposition()
      b.write_char('{')
      b.write_string("\"name\":")
      match d {
        Some(d) =>
          match d.param("name") {
            Some(n) => b.write_string(jstr(n))
            None => b.write_string("null")
          }
        None => b.write_string("null")
      }
      b.write_string(",\"filename\":")
      match d {
        Some(d) =>
          match d.filename() {
            Some(f) => b.write_string(jstr(f))
            None => b.write_string("null")
          }
        None => b.write_string("null")
      }
      b.write_string(",\"content_type\":")
      match p.content_type() {
        Some(mt) => b.write_string(jstr(mt.to_string()))
        None => b.write_string("\"\"")
      }
      b.write_string(",\"size\":")
      b.write_string(p.body.length().to_string())
      b.write_string(",\"body\":")
      b.write_string(jstr(@utf8.decode_lossy(p.body[:])))
      b.write_char('}')
    }
    b.write_char(']')
    return b.to_string()
  } catch {
    _ => return "{\"error\":true}"
  }
}

///|
/// Read a `multipart/form-data` body into its text fields and its files.
pub fn browser_formdata(body : String, boundary : String) -> String {
  try {
    let form = @moonmime.formdata(bytes_of(body)[:], boundary[:])
    let b = StringBuilder()
    b.write_string("{\"fields\":[")
    let fields = form.entries()
    for i = 0; i < fields.length(); i = i + 1 {
      if i > 0 {
        b.write_char(',')
      }
      b.write_string("{\"name\":")
      b.write_string(jstr(fields[i].name))
      b.write_string(",\"value\":")
      b.write_string(jstr(fields[i].value))
      b.write_char('}')
    }
    b.write_string("],\"files\":[")
    let files = form.uploads()
    for i = 0; i < files.length(); i = i + 1 {
      if i > 0 {
        b.write_char(',')
      }
      b.write_string("{\"name\":")
      b.write_string(jstr(files[i].name))
      b.write_string(",\"filename\":")
      b.write_string(jstr(files[i].filename))
      b.write_string(",\"content_type\":")
      b.write_string(jstr(files[i].content_type))
      b.write_string(",\"size\":")
      b.write_string(files[i].size().to_string())
      b.write_char('}')
    }
    b.write_string("],\"is_empty\":")
    b.write_string(if form.is_empty() { "true" } else { "false" })
    b.write_char('}')
    return b.to_string()
  } catch {
    _ => return "{\"error\":true}"
  }
}

///|
/// entry point required by the executable package; the page calls the
/// exported functions instead.
fn main {
  ignore(browser_guess_type("demo.png"))
}
