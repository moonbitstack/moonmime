// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Octets on their way out: what a caller's sink takes, a piece at a time.
///
/// The writer hands over the delimiter, the header block and the body octets of
/// a part as it is given them, so a body larger than memory never stands in it.
///
/// ```mbt check
/// test {
///   let gathered = @moonmime.Gathered::new()
///   let writer = @moonmime.MultipartWriter::new(gathered, boundary="b")
///   writer.begin_part([("content-type", "text/plain")])
///   writer.body(b"hola")
///   writer.close()
///   let parts = @moonmime.multipart(gathered.bytes()[:], "b")
///   inspect(parts[0].body, content="b\"hola\"")
/// }
/// ```
pub(open) trait Sink {
  fn write(Self, BytesView) -> Unit raise
}

///|
/// A sink that keeps what it is handed, for a caller that wants the octets
/// after all.
struct Gathered {
  held : Array[Byte]
}

///|
pub fn Gathered::new() -> Gathered {
  { held: [], }
}

///|
/// Everything written so far, as one value.
pub fn Gathered::bytes(self : Gathered) -> Bytes {
  Bytes::from_array(self.held)
}

///|
pub impl Sink for Gathered with fn write(self, chunk) {
  for i = 0; i < chunk.length(); i = i + 1 {
    self.held.push(chunk[i])
  }
}

///|
pub extend Gathered with Sink::{write}

///|
/// Writes a multipart body a part at a time: the delimiter and header block
/// when a part begins, its body octets as they are handed over, and the closing
/// delimiter when it ends.
///
/// The boundary is the caller's or a fixed stem, and the octets that would make
/// it a delimiter inside a part are watched for as they go by: a body that
/// holds the boundary is refused at that point rather than framed into a body
/// the receiver would split somewhere else. A refusal cannot take back what the
/// sink already holds, which is why a caller that cannot lose the octets passes
/// a boundary of its own.
///
/// ```mbt check
/// test {
///   let gathered = @moonmime.Gathered::new()
///   let writer = @moonmime.MultipartWriter::new(gathered, boundary="b")
///   inspect(writer.content_type(), content="multipart/mixed; boundary=b")
///   writer.begin_part([("content-type", "text/plain")])
///   writer.body(b"hola")
///   writer.begin_part([("content-type", "text/html")])
///   writer.body(b"<b>hola</b>")
///   writer.close()
///   let parts = @moonmime.multipart(gathered.bytes()[:], "b")
///   inspect(parts.length(), content="2")
///   inspect(parts[1].body, content="b\"<b>hola</b>\"")
/// }
/// ```
struct MultipartWriter {
  sink : &Sink
  kind : MultipartKind
  boundary : String
  needle : Bytes
  mut held : Array[Byte]
  mut parts : Int32
  mut open : Bool
  mut closed : Bool
}

///|
/// A writer that frames parts for `sink`.
///
/// The boundary is generated when the caller gives none: a fixed stem, so the
/// same parts always frame the same way. Unlike a body written in one call it
/// cannot be proven absent from parts that have not arrived yet, so it is
/// watched for as they go by and a collision is refused.
pub fn MultipartWriter::new(
  sink : &Sink,
  boundary? : StringView,
  kind~ : MultipartKind = Mixed,
) -> MultipartWriter raise Refused {
  let boundary = match boundary {
    Some(given) => {
      let given = given.to_owned()
      guard is_boundary(given[:]) else { raise Boundary(got=given) }
      given
    }
    None => "----moonmime"
  }
  {
    sink,
    kind,
    boundary,
    needle: ascii("--" + boundary),
    held: [],
    parts: 0,
    open: false,
    closed: false,
  }
}

///|
/// The boundary the delimiters are written with.
pub fn MultipartWriter::boundary(self : MultipartWriter) -> String {
  self.boundary
}

///|
/// The `Content-Type` that goes with the body, to be written before or beside
/// it: the subtype and the boundary the receiver splits on.
pub fn MultipartWriter::content_type(self : MultipartWriter) -> String {
  content_type_of(self.kind, self.boundary[:])
}

///|
/// Begin a part: its delimiter, then its header fields and the empty line that
/// ends them.
///
/// A part is over when the next one begins; there is nothing to write between
/// them but the delimiter, which carries the CRLF the receiver reads as the end
/// of the previous body.
pub fn MultipartWriter::begin_part(
  self : MultipartWriter,
  headers : Array[(String, String)],
) -> Unit raise {
  guard !self.closed else {
    abort("moonmime: a part began after the body closed")
  }
  let delimiter = if self.parts == 0 {
    "--" + self.boundary + "\r\n"
  } else {
    "\r\n--" + self.boundary + "\r\n"
  }
  self.sink.write(@utf8.encode(delimiter)[:])
  self.held = []
  for pair in headers {
    self.put(@utf8.encode(canonical(pair.0) + ": " + pair.1 + "\r\n"))
  }
  self.put(b"\r\n")
  self.parts = self.parts + 1
  self.open = true
}

///|
/// The next octets of the current part's body.
pub fn MultipartWriter::body(
  self : MultipartWriter,
  bytes : BytesView,
) -> Unit raise {
  guard self.open else { abort("moonmime: a body arrived before a part began") }
  self.put(bytes)
}

///|
/// Write the closing delimiter. Closing a body with no parts writes it alone,
/// which is the shape a reader takes for a body that carries none.
pub fn MultipartWriter::close(self : MultipartWriter) -> Unit raise {
  if self.closed {
    return
  }
  let delimiter = if self.parts == 0 {
    "--" + self.boundary + "--\r\n"
  } else {
    "\r\n--" + self.boundary + "--\r\n"
  }
  self.sink.write(@utf8.encode(delimiter)[:])
  self.closed = true
  self.open = false
}

///|
/// Hand octets to the sink, after watching them for the delimiter.
fn MultipartWriter::put(
  self : MultipartWriter,
  bytes : BytesView,
) -> Unit raise {
  self.watch(bytes)
  self.sink.write(bytes)
}

///|
/// Look for the delimiter in `bytes` and across the junction with what was held
/// back from the previous piece.
///
/// The junction is all a straddling delimiter can start in: a delimiter is
/// shorter than the octets a part keeps, so any match that begins earlier than
/// this piece has been seen already.
fn MultipartWriter::watch(
  self : MultipartWriter,
  bytes : BytesView,
) -> Unit raise {
  let keep = self.needle.length() - 1
  let head = if bytes.length() < keep { bytes.length() } else { keep }
  let joined : Array[Byte] = []
  for byte in self.held {
    joined.push(byte)
  }
  for i = 0; i < head; i = i + 1 {
    joined.push(bytes[i])
  }
  if index_of(Bytes::from_array(joined)[:], self.needle[:], 0) >= 0 ||
    index_of(bytes, self.needle[:], 0) >= 0 {
    raise Boundary(got=self.boundary)
  }
  let next : Array[Byte] = []
  if bytes.length() >= keep {
    for i = bytes.length() - keep; i < bytes.length(); i = i + 1 {
      next.push(bytes[i])
    }
  } else {
    let need = keep - bytes.length()
    let from = if self.held.length() > need {
      self.held.length() - need
    } else {
      0
    }
    for i = from; i < self.held.length(); i = i + 1 {
      next.push(self.held[i])
    }
    for i = 0; i < bytes.length(); i = i + 1 {
      next.push(bytes[i])
    }
  }
  self.held = next
}
