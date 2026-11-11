// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// One part of a multipart body: its header fields and its body octets.
#derive(Eq, Debug)
pub(all) struct Part {
  headers : Array[(String, String)]
  body : Bytes
}

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
/// The part's `Content-ID` without its angle brackets, which is the form the
/// `start` parameter of `multipart/related` names it by; `None` when it has
/// none.
pub fn Part::content_id(self : Part) -> String? {
  match self.header("content-id") {
    Some(value) => Some(content_id_of(value[:]))
    None => None
  }
}

///|
/// What a body is allowed to be.
///
/// A body arrives from whoever sent it, so both bounds are needed: a million
/// empty parts and one enormous part are different ways of asking a server to
/// allocate more than it has.
#derive(Eq, Debug)
pub(all) struct Limits {
  parts : Int32
  part_size : Int32
}

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
#derive(Eq, Debug)
pub(all) suberror Refused {
  /// More parts than allowed.
  Parts(limit~ : Int32)
  /// One part longer than allowed.
  Part(limit~ : Int32, got~ : Int32)
  /// A body that stops making sense at this offset. Only raised under
  /// `strict`; otherwise the parts read so far are returned.
  Malformed(at~ : Int32)
  /// A charset neither shipped nor passed in, by its lower-cased name.
  Charset(name~ : String)
  /// A content type that is not a form encoding, for whoever picks a decoder by
  /// `Content-Type` and was asked to say so.
  NotAForm(content_type~ : String)
  /// A content type that is not `multipart/related`, for the same reason.
  NotRelated(content_type~ : String)
  /// A boundary that cannot delimit the body it was given: not RFC 2046's
  /// bchars, longer than the 70 octets it allows, or already standing inside a
  /// part, where a receiver would split on it.
  Boundary(got~ : String)
}

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
///
/// This is the reader in `PartsReader` walked to its end: a caller that does
/// not want the whole body in hand reads the parts as they arrive instead, and
/// gets the same parts out.
pub fn multipart(
  body : BytesView,
  boundary : StringView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> Array[Part] raise Refused {
  let reader = PartsReader::over(body, boundary, limits~, strict~)
  let parts : Array[Part] = []
  let mut more = true
  while more {
    match reader.next_part() {
      Some(head) => {
        let out : Array[Byte] = []
        let mut reading = true
        while reading {
          match reader.read() {
            Some(chunk) =>
              for i = 0; i < chunk.length(); i = i + 1 {
                out.push(chunk[i])
              }
            None => reading = false
          }
        }
        parts.push({ headers: head.headers, body: Bytes::from_array(out), })
      }
      None => more = false
    }
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
  let line = unfolded(block)
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
/// A header block with its folded lines closed up.
///
/// RFC 5322 §2.2.3 lets a field run over several lines when each continuation
/// starts with whitespace, and the break stands for nothing: the whitespace
/// that opens the continuation is kept and the CRLF is dropped. Writers fold
/// long fields this way — a long `filename` is folded before its own `;` — so a
/// reader that stopped at the first line would read a truncated name.
fn unfolded(block : BytesView) -> String {
  let raw = text(block)
  let n = raw.length()
  let out = StringBuilder()
  let mut i = 0
  while i < n {
    let c = raw.at(i).to_int()
    if c == 0x0D && i + 2 < n && raw.at(i + 1).to_int() == 0x0A {
      let next = raw.at(i + 2).to_int()
      if next == 0x20 || next == 0x09 {
        i = i + 2
        continue
      }
    }
    if c == 0x0A && i + 1 < n {
      let next = raw.at(i + 1).to_int()
      if next == 0x20 || next == 0x09 {
        i = i + 1
        continue
      }
    }
    out.write_view(raw[i:i + 1])
    i = i + 1
  }
  out.to_string()
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
/// A `Content-ID` as it is compared: the address inside the angle brackets.
///
/// RFC 2045 writes the identification in angle brackets and RFC 2387's `start`
/// quotes a content ID, with or without them; taking the brackets off both
/// sides is what makes the two meet.
fn content_id_of(value : StringView) -> String {
  let text = value.trim()
  if text.length() >= 2 &&
    text.at(0).to_int() == 0x3C &&
    text.at(text.length() - 1).to_int() == 0x3E {
    return text[1:text.length() - 1].to_owned()
  }
  text.to_owned()
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
