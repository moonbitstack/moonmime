// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body as octets. The page's helper: it turns a string literal into the
/// bytes a request would carry.
fn octets(text : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < text.length(); i = i + 1 {
    out.push((text.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// One part of a form, as the octets a browser sends, in a body of two.
let upload : String = "------edge\r\n" +
  "Content-Disposition: form-data; name=\"title\"\r\n" +
  "\r\n" +
  "a report\r\n" +
  "------edge\r\n" +
  "Content-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\n" +
  "Content-Type: text/plain\r\n" +
  "\r\n" +
  "line one\r\nline two\r\n" +
  "------edge--\r\n"

///|
/// A body arriving the way a socket delivers one: a piece at a time, with the
/// reader pulling only what it needs.
struct Pieces {
  body : Bytes
  size : Int32
  mut at : Int32
  mut given : Int32
}

///|
impl @moonmime.Source for Pieces with fn next(self) {
  if self.at >= self.body.length() {
    return None
  }
  let to = if self.at + self.size > self.body.length() {
    self.body.length()
  } else {
    self.at + self.size
  }
  let piece : Array[Byte] = []
  for i = self.at; i < to; i = i + 1 {
    piece.push(self.body[i])
  }
  self.given = self.given + (to - self.at)
  self.at = to
  Some(Bytes::from_array(piece))
}

///|
/// A sink that keeps what it is handed and says how much it holds.
struct Tally {
  held : Array[Byte]
  mut pieces : Int32
}

///|
impl @moonmime.Sink for Tally with fn write(self, chunk) {
  for i = 0; i < chunk.length(); i = i + 1 {
    self.held.push(chunk[i])
  }
  self.pieces = self.pieces + 1
}

///|
fn text(bytes : BytesView) -> String {
  @utf8.decode_lossy(bytes)
}

///|
fn main raise {
  // ------------------------------------------------- reading as it arrives
  //
  // The head of a part comes first, so a caller can decide whether it wants the
  // body before a single octet of it is read: a field nobody asked for is
  // dropped without being held.
  let source = Pieces::{ body: octets(upload), size: 12, at: 0, given: 0, }
  let reader = @moonmime.PartsReader::new(source, "----edge")
  let mut more = true
  while more {
    match reader.next_part() {
      Some(head) => {
        let name = head
          .disposition()
          .map(d => d.param("name").unwrap_or(""))
          .unwrap_or("")
        let filename = head
          .disposition()
          .map(d => d.filename().unwrap_or(""))
          .unwrap_or("")
        println("part " + name + " " + filename)
        let body = StringBuilder()
        let mut reading = true
        while reading {
          match reader.read() {
            Some(chunk) => body.write_string(text(chunk))
            None => reading = false
          }
        }
        println("  " + body.to_string().replace_all(old="\r\n", new="\\r\\n"))
      }
      None => more = false
    }
  }
  println(
    "pulled " +
    source.given.to_string() +
    " of " +
    source.body.length().to_string(),
  )

  // A head costs the octets up to it and no more. A caller that wants one field
  // stops after the first head; what stands behind it is never pulled.
  let peek = Pieces::{ body: octets(upload), size: 12, at: 0, given: 0, }
  let early = @moonmime.PartsReader::new(peek, "----edge")
  println(
    early.next_part().unwrap().header("content-disposition").unwrap_or(""),
  )
  println(
    "pulled " + peek.given.to_string() + " of " + peek.body.length().to_string(),
  )

  // ------------------------------------------------- writing a part at a time
  //
  // The writer hands over the delimiter, the header block and the body octets
  // as it is given them: nothing waits for the part to end.
  let sink = Tally::{ held: [], pieces: 0, }
  let writer = @moonmime.MultipartWriter::new(sink, boundary="----edge")
  println(writer.content_type())
  let parts = @moonmime.Form::new(
    fields=[{ name: "title", value: "a report", }],
    files=[
      {
        name: "file",
        filename: "notes.txt",
        content_type: "text/plain",
        content: octets("line one\r\nline two"),
        headers: [],
      },
    ],
  ).parts()
  for part in parts {
    writer.begin_part(part.headers)
    writer.body(part.body)
    println(
      "  " +
      sink.pieces.to_string() +
      " pieces, " +
      sink.held.length().to_string() +
      " octets",
    )
  }
  writer.close()
  println(
    sink.pieces.to_string() +
    " pieces, " +
    sink.held.length().to_string() +
    " octets",
  )

  // What the writer framed is what the reader reads, part for part.
  let read_back = @moonmime.formdata(
    Bytes::from_array(sink.held)[:],
    "----edge",
  )
  println(read_back.field("title").unwrap_or(""))
  println(read_back.file("file").unwrap().filename)

  // ----------------------------------------------------------- a related body
  //
  // The parameters say what the parts are and which one is the root; the
  // framing is the one every multipart subtype shares.
  let related = @moonmime.Related::new(
    [
      {
        headers: [("content-id", "<logo>"), ("content-type", "image/png")],
        body: b"\x89PNG",
      },
      {
        headers: [("content-id", "<root>"), ("content-type", "text/html")],
        body: b"<img src=\"cid:logo\">",
      },
    ],
    boundary="----rel",
    type_="text/html",
    start="<root>",
  )
  println(related.content_type())
  let back = @moonmime.related(related.content_type(), related.body()) catch {
    e => abort("the header this library wrote was refused: \{e.to_repr()}")
  }
  let root = back.root().unwrap()
  println(
    "the root is " +
    root.content_id().unwrap_or("") +
    ", " +
    root.content_type().unwrap().essence,
  )
  println(back.parts.length().to_string() + " parts")
}
