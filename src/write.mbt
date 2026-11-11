// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Which multipart type a written body announces.
///
/// RFC 2046 §5.1 is the framing either way; the subtype says what the parts
/// mean. `FormData` is the one a form upload carries (RFC 7578), `Mixed` the
/// one an email with an attachment carries (RFC 2046 §5.1.3).
#derive(Eq, Debug)
pub(all) enum MultipartKind {
  FormData
  Mixed
}

///|
pub extend MultipartKind with Eq::{equal, not_equal}

///|
pub extend MultipartKind with Debug::{to_repr}

///|
/// The subtype as it is written on the wire: the half that follows
/// `multipart/`.
pub fn MultipartKind::code(self : MultipartKind) -> String {
  match self {
    MultipartKind::FormData => "form-data"
    MultipartKind::Mixed => "mixed"
  }
}

///|
/// A multipart body on its way out: the octets, the boundary that delimits
/// them, and the subtype the two have to agree on.
///
/// The octets are what a `Content-Type` of `content_type()` describes and what
/// `multipart` reads back with the same `boundary`.
#derive(Eq, Debug)
pub(all) struct Multipart {
  kind : MultipartKind
  boundary : String
  body : Bytes
}

///|
pub extend Multipart with Eq::{equal, not_equal}

///|
pub extend Multipart with Debug::{to_repr}

///|
/// Frame `parts` as a multipart body (RFC 2046 §5.1).
///
/// A part's headers go out in the order the part holds them, with a lowercased
/// name — the shape a parse hands back — restored to `Content-Type` casing. A
/// part with no headers at all is still a part: it is delimited like any other
/// and its body is read back as it stands.
///
/// The boundary is generated when the caller gives none, from a fixed stem and
/// a single pass over the parts, so the same parts always come out as the same
/// octets and the boundary is proven absent from them rather than merely
/// unlikely. A caller that gives one keeps control of what the receiver sees —
/// the dash-stem browsers use, or a value it has already named elsewhere.
///
/// ```mbt check
/// test {
///   let form = @moonmime.Form::new(fields=[{ name: "title", value: "a report", }])
///   let body = form.encode(boundary="----edge")
///   inspect(body.content_type(), content="multipart/form-data; boundary=----edge")
///   let read = @moonmime.formdata(body.body[:], body.boundary)
///   inspect(read.field("title").unwrap_or(""), content="a report")
/// }
/// ```
pub fn Multipart::new(
  parts : Array[Part],
  boundary? : StringView,
  kind~ : MultipartKind = Mixed,
) -> Multipart raise Refused {
  let blocks : Array[Bytes] = parts.map(part_block)
  let boundary = choose_boundary(blocks, boundary)
  { kind, boundary, body: framed_body(blocks, boundary[:]), }
}

///|
/// The boundary a body goes out with: the caller's, checked, or one proven
/// absent from every part of the body.
fn choose_boundary(
  blocks : Array[Bytes],
  boundary : StringView?,
) -> String raise Refused {
  match boundary {
    Some(given) => {
      let given = given.to_owned()
      guard is_boundary(given[:]) else { raise Boundary(got=given) }
      guard !collides(blocks, given[:]) else { raise Boundary(got=given) }
      given
    }
    None => free_boundary(blocks)
  }
}

///|
/// The parts framed between delimiters, opening to closing.
fn framed_body(blocks : Array[Bytes], boundary : StringView) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < blocks.length(); i = i + 1 {
    if i == 0 {
      push_text(out, "--" + boundary.to_owned() + "\r\n")
    } else {
      push_text(out, "\r\n--" + boundary.to_owned() + "\r\n")
    }
    push_bytes(out, blocks[i][:])
  }
  // A body with no parts is the closing delimiter alone: an opening one would
  // leave a blank line a reader could take for a part.
  if blocks.length() == 0 {
    push_text(out, "--" + boundary.to_owned() + "--\r\n")
  } else {
    push_text(out, "\r\n--" + boundary.to_owned() + "--\r\n")
  }
  Bytes::from_array(out)
}

///|
/// The `Content-Type` a body of this subtype and boundary goes out with.
fn content_type_of(kind : MultipartKind, boundary : StringView) -> String {
  MediaType::{
    essence: "multipart/" + kind.code(),
    params: [("boundary", boundary.to_owned())],
  }.to_string()
}

///|
/// The `Content-Type` that goes with the body: the subtype, and the boundary
/// the receiver needs to split it.
///
/// Written as a header value, so a boundary with a space in it — RFC 2046
/// allows the space, not as the last character — comes out quoted.
pub fn Multipart::content_type(self : Multipart) -> String {
  content_type_of(self.kind, self.boundary[:])
}

///|
/// Write the form as a `multipart/form-data` body (RFC 7578).
///
/// Fields go out first, then files, each in the order the form holds them: a
/// `Form` keeps the two apart, so it cannot reproduce the interleaving of the
/// body it was read from. A file whose name leaves ASCII is named with
/// `filename*` (RFC 5987), the one form a receiver decodes back to the same
/// characters.
pub fn Form::encode(
  self : Form,
  boundary? : StringView,
) -> Multipart raise Refused {
  Multipart::new(self.parts(), boundary?, kind=FormData)
}

// ------------------------------------------------------------- the form's parts

///|
fn form_parts(form : Form) -> Array[Part] {
  let parts : Array[Part] = []
  for field in form.fields {
    parts.push({
      headers: [
        ("content-disposition", "form-data; name=" + quoted(field.name)),
      ],
      body: @utf8.encode(field.value),
    })
  }
  for upload in form.files {
    let mut disposition = "form-data; name=" + quoted(upload.name)
    if upload.filename != "" {
      disposition = disposition + "; " + filename_param(upload.filename)
    }
    let headers : Array[(String, String)] = [
      ("content-disposition", disposition),
    ]
    if upload.content_type != "" {
      headers.push(("content-type", upload.content_type))
    }
    for pair in upload.headers {
      // These two are decided by the upload's own fields above; a second copy
      // would be the receiver's guess at which one is meant.
      if pair.0 != "content-disposition" && pair.0 != "content-type" {
        headers.push(pair)
      }
    }
    parts.push({ headers, body: upload.content, })
  }
  parts
}

///|
/// `name="..."` for a parameter of a form part. The quotes are the whole of the
/// framing: a name is text a person typed, so the only characters that cannot
/// stand inside are the ones that end the string.
fn quoted(value : StringView) -> String {
  let out = StringBuilder()
  out.write_char('"')
  for i in 0..<value.length() {
    let c = value.at(i).to_int()
    if c == 0x22 || c == 0x5C {
      out.write_char('\\')
    }
    out.write_view(value[i:i + 1])
  }
  out.write_char('"')
  out.to_string()
}

// --------------------------------------------------------------- the octets

///|
/// One part as it stands between two delimiters: its headers, the empty line
/// that ends them, and its body.
fn part_block(part : Part) -> Bytes {
  let out : Array[Byte] = []
  for pair in part.headers {
    push_text(out, canonical(pair.0))
    push_text(out, ": ")
    push_text(out, pair.1)
    push_text(out, "\r\n")
  }
  push_text(out, "\r\n")
  push_bytes(out, part.body[:])
  Bytes::from_array(out)
}

///|
/// A field name for the wire. A name that came back from a parse is lowercased,
/// and goes out the way every writer spells it: each word capitalised.
fn canonical(name : String) -> String {
  for i in 0..<name.length() {
    let c = name.at(i).to_int()
    if c >= 0x41 && c <= 0x5A {
      return name
    }
  }
  let out = StringBuilder()
  let mut at_word = true
  for i = 0; i < name.length(); i = i + 1 {
    let c = name.at(i).to_int()
    if at_word && c >= 0x61 && c <= 0x7A {
      out.write_char((c - 0x20).unsafe_to_char())
    } else {
      out.write_view(name[i:i + 1])
    }
    at_word = c == 0x2D
  }
  out.to_string()
}

///|
fn push_text(out : Array[Byte], text : String) -> Unit {
  push_bytes(out, @utf8.encode(text)[:])
}

///|
fn push_bytes(out : Array[Byte], bytes : BytesView) -> Unit {
  for i = 0; i < bytes.length(); i = i + 1 {
    out.push(bytes[i])
  }
}

// ------------------------------------------------------------- the boundary

///|
/// A boundary proven absent from the parts, so it can only ever be a delimiter.
///
/// The stem is fixed and the suffix counts attempts, which makes the choice a
/// function of the parts: no source of randomness, and the same parts always
/// frame the same way. A part that already holds the candidate — a nested body
/// written by this library, most often — moves the count on.
fn free_boundary(blocks : Array[Bytes]) -> String {
  let mut n = 0
  let mut candidate = "----moonmime"
  while collides(blocks, candidate[:]) {
    n = n + 1
    candidate = "----moonmime" + n.to_string()
  }
  candidate
}

///|
/// Whether `--boundary` already stands inside one of the parts.
fn collides(blocks : Array[Bytes], boundary : StringView) -> Bool {
  let needle = ascii("--" + boundary.to_owned())
  for block in blocks {
    if index_of(block[:], needle[:], 0) >= 0 {
      return true
    }
  }
  false
}

///|
/// Whether a value can delimit a body: RFC 2046 §5.1 allows up to 70 octets of
/// bchars, and a space anywhere but the end.
fn is_boundary(s : StringView) -> Bool {
  let n = s.length()
  if n == 0 || n > 70 || s.at(n - 1).to_int() == 0x20 {
    return false
  }
  for i = 0; i < n; i = i + 1 {
    match s.at(i).to_int() {
      '0'..<='9'
      | 'A'..<='Z'
      | 'a'..<='z'
      | '\''
      | '('
      | ')'
      | '+'
      | '_'
      | ','
      | '-'
      | '.'
      | '/'
      | ':'
      | '='
      | '?'
      | ' ' => ()
      _ => return false
    }
  }
  true
}
