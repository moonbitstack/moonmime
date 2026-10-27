// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One part of a multipart body: its header fields and its body octets.
pub(all) struct Part {
  headers : Array[(String, String)]
  body : Bytes
} derive(Eq, Debug)

///|
pub extend Part with Eq::{equal, not_equal}

///|
pub extend Part with Debug::{to_repr}

///|
/// One of the part's own headers, by lowercased name.
pub fn Part::header(self : Part, name : StringView) -> String? {
  header_of(self.headers, name)
}

///|
/// The part's `Content-Type`, parsed; `None` when it has none.
pub fn Part::content_type(self : Part) -> MediaType? {
  match self.header("content-type") {
    Some(value) => Some(media_type(value[:]))
    None => None
  }
}

///|
/// The part's `Content-Disposition`, parsed; `None` when it has none.
pub fn Part::disposition(self : Part) -> Disposition? {
  match self.header("content-disposition") {
    Some(value) => Some(Disposition::parse(value[:]))
    None => None
  }
}

///|
/// What a body is allowed to be.
///
/// A body arrives from whoever sent it, so both bounds are needed: a million
/// empty parts and one enormous part are different ways of asking a server to
/// allocate more than it has.
pub(all) struct Limits {
  parts : Int32
  part_size : Int32
} derive(Eq, Debug)

///|
pub extend Limits with Eq::{equal, not_equal}

///|
pub extend Limits with Debug::{to_repr}

///|
/// A thousand parts of a megabyte each — a bound wide enough for a usual form
/// upload, tight enough to stop a body from asking for more than a server has.
/// A caller that knows its own shape should say so.
pub let limits : Limits = { parts: 1000, part_size: 1 << 20, }

///|
/// Build a bound by naming the parts that differ from the default.
pub fn Limits::new(
  parts~ : Int32 = limits.parts,
  part_size~ : Int32 = limits.part_size,
) -> Limits {
  { parts, part_size, }
}

///|
/// Why a body was not read as a form.
///
/// A body over its bounds is refused whole rather than truncated: a handler
/// given the first thousand parts of a larger body would be answering a request
/// nobody sent.
pub(all) suberror Refused {
  /// More parts than allowed.
  Parts(limit~ : Int32)
  /// One part longer than allowed.
  Part(limit~ : Int32, got~ : Int32)
  /// A body that stops making sense at this offset. Only raised under
  /// `strict`; otherwise the parts read so far are returned.
  Malformed(at~ : Int32)
  /// A content type that is not a form encoding, for whoever picks a decoder by
  /// `Content-Type` and was asked to say so.
  NotAForm(content_type~ : String)
} derive(Eq, Debug)

///|
pub extend Refused with Eq::{equal, not_equal}

///|
pub extend Refused with Debug::{to_repr}

///|
/// Split a multipart body into its parts (RFC 2046 §5.1) given its boundary.
///
/// Preamble and epilogue are dropped; the two CRLF before each delimiter belong
/// to the delimiter, not to the part. A body that stops making sense returns
/// what it read so far, unless `strict` says to refuse it.
pub fn multipart(
  body : BytesView,
  boundary : StringView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> Array[Part] raise Refused {
  let parts : Array[Part] = []
  let dash = ascii("--" + boundary.to_owned())
  let mut pos = index_of(body, dash[:], 0)
  while pos >= 0 {
    let after = pos + dash.length()
    // `--boundary--` closes the body; there is nothing after it but an epilogue.
    if has_at(body, after, b"--"[:]) {
      break
    }
    let head = if has_at(body, after, b"\r\n"[:]) { after + 2 } else { after }
    let blank = index_of(body, b"\r\n\r\n"[:], head)
    let next = index_of(body, dash[:], head)
    if blank < 0 || next < 0 || blank > next {
      // Inventing a structure for the rest would be deciding what the sender
      // meant, so the choice is between stopping with what was read and saying
      // so; `strict` is which.
      if strict {
        raise Malformed(at=head)
      }
      break
    }
    if parts.length() == limits.parts {
      raise Parts(limit=limits.parts)
    }
    let headers = part_headers(body[head:blank])
    let from = blank + 4
    // The two bytes before the next delimiter are this part's own trailing
    // CRLF and are not content.
    let to = if next - 2 < from { from } else { next - 2 }
    if to - from > limits.part_size {
      raise Part(limit=limits.part_size, got=to - from)
    }
    parts.push({ headers, body: body[from:to].to_owned(), })
    pos = next
  }
  parts
}

// ----------------------------------------------------------------- the pieces

///|
/// A part's header block, as lowercased name and value.
///
/// A line with no colon is not a header field and is dropped rather than
/// guessed at.
fn part_headers(block : BytesView) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  let line = text(block)
  let n = line.length()
  let mut start = 0
  for i = 0; i <= n; i = i + 1 {
    if i == n || line.at(i).to_int() == 0x0A {
      let end = if i > start && line.at(i - 1).to_int() == 0x0D {
        i - 1
      } else {
        i
      }
      let one = line[start:end]
      let mut colon = -1
      for j = 0; j < one.length(); j = j + 1 {
        if one.at(j).to_int() == 0x3A {
          colon = j
          break
        }
      }
      if colon > 0 {
        out.push((trim(one[0:colon]).to_lower(), trim(one[colon + 1:])))
      }
      start = i + 1
    }
  }
  out
}

///|
fn header_of(headers : Array[(String, String)], name : StringView) -> String? {
  for pair in headers {
    if pair.0[:] == name {
      return Some(pair.1)
    }
  }
  None
}

///|
/// Bytes as text, with anything that is not UTF-8 replaced rather than refused.
fn text(raw : BytesView) -> String {
  @utf8.decode_lossy(raw)
}

///|
fn ascii(s : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < s.length(); i = i + 1 {
    out.push((s.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
fn has_at(hay : BytesView, at : Int32, needle : BytesView) -> Bool {
  if at < 0 || at + needle.length() > hay.length() {
    return false
  }
  for i = 0; i < needle.length(); i = i + 1 {
    if hay[at + i] != needle[i] {
      return false
    }
  }
  true
}

///|
fn index_of(hay : BytesView, needle : BytesView, from : Int32) -> Int32 {
  let last = hay.length() - needle.length()
  for i = from; i <= last; i = i + 1 {
    if has_at(hay, i, needle) {
      return i
    }
  }
  -1
}
