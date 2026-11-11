// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A `multipart/related` body (RFC 2387): a compound object whose parts belong
/// together, one of them the root the rest hang off.
///
/// The framing is the one every multipart subtype shares; what this type adds
/// is the three parameters that say what the parts are — `type` for the media
/// type of the root, `start` for the root's `Content-ID`, `start-info` passed
/// through to that type — and the reading of `start` back into the part it
/// names.
///
/// `parts` is what a reader found and what a writer frames; `body()` writes the
/// octets those parts frame to, so a value read from a body that carried a
/// preamble or a folded header writes back this library's own framing of the
/// same parts.
#derive(Eq, Debug)
pub(all) struct Related {
  type_ : String
  start : String
  start_info : String
  boundary : String
  parts : Array[Part]
}

///|
pub extend Related with Eq::{equal, not_equal}

///|
pub extend Related with Debug::{to_repr}

///|
/// A related body of `parts`.
///
/// The boundary works as it does for any other multipart body: the caller's,
/// checked against RFC 2046 and against the parts, or generated from a stem
/// stepped on until it is proven absent.
///
/// Left without parts the value is the header alone, which is what a caller
/// streaming the body needs: the writer frames the parts, the value names them.
///
/// ```mbt check
/// test {
///   let related = @moonmime.Related::new(
///     [
///       @moonmime.Part::{
///         headers: [("content-id", "<root>"), ("content-type", "text/html")],
///         body: b"<b>hola</b>",
///       },
///     ],
///     boundary="b",
///     type_="text/html",
///     start="<root>",
///   )
///   inspect(
///     related.content_type(),
///     content="multipart/related; boundary=b; type=\"text/html\"; start=\"<root>\"",
///   )
///   inspect(related.root().unwrap().body, content="b\"<b>hola</b>\"")
/// }
/// ```
pub fn Related::new(
  parts : Array[Part],
  boundary? : StringView,
  type_~ : String = "",
  start~ : String = "",
  start_info~ : String = "",
) -> Related raise Refused {
  let blocks : Array[Bytes] = parts.map(part_block)
  {
    type_,
    start,
    start_info,
    boundary: choose_boundary(blocks, boundary),
    parts,
  }
}

///|
/// Read a `multipart/related` body given the `Content-Type` that announces it.
///
/// The parameters come off the header, the parts off the body; `root()` is what
/// ties the two together.
pub fn related(
  content_type : StringView,
  body : BytesView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> Related raise Refused {
  let header = media_type(content_type)
  guard header.essence == "multipart/related" else {
    raise NotRelated(content_type=content_type.to_owned())
  }
  let boundary = match header.param("boundary") {
    Some(boundary) => boundary
    None => raise Boundary(got="")
  }
  {
    type_: header.param("type").unwrap_or(""),
    start: header.param("start").unwrap_or(""),
    start_info: header.param("start-info").unwrap_or(""),
    boundary,
    parts: multipart(body, boundary[:], limits~, strict~),
  }
}

///|
/// The body the parts frame to, delimited by this value's boundary.
pub fn Related::body(self : Related) -> Bytes {
  framed_body(self.parts.map(part_block), self.boundary[:])
}

///|
/// The `Content-Type` that announces this body: `boundary` first, because the
/// receiver cannot read the parts without it, then the three parameters RFC 2387
/// defines, in the order it names them. A parameter that was not given is not
/// written.
pub fn Related::content_type(self : Related) -> String {
  let params : Array[(String, String)] = [("boundary", self.boundary)]
  if self.type_ != "" {
    params.push(("type", self.type_))
  }
  if self.start != "" {
    params.push(("start", self.start))
  }
  if self.start_info != "" {
    params.push(("start-info", self.start_info))
  }
  MediaType::{ essence: "multipart/related", params, }.to_string()
}

///|
/// The root part: the one `start` names by its `Content-ID`, or the first part
/// when the header names none, which is RFC 2387's default.
///
/// `None` when the header names a part the body does not hold, which is a
/// disagreement between the two halves rather than something to guess at.
pub fn Related::root(self : Related) -> Part? {
  if self.start == "" {
    if self.parts.length() == 0 {
      return None
    }
    return Some(self.parts[0])
  }
  let want = content_id_of(self.start[:])
  for part in self.parts {
    match part.content_id() {
      Some(id) => if id == want { return Some(part) }
      None => ()
    }
  }
  None
}
