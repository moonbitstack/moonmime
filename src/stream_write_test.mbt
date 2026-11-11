// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn as_bytes(value : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < value.length(); i = i + 1 {
    out.push((value.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A sink that keeps every piece it is handed, in the order it arrives, and
/// remembers how many pieces there were.
struct Recorder {
  held : Array[Byte]
  mut calls : Int32
  sizes : Array[Int32]
}

///|
fn Recorder::new() -> Recorder {
  { held: [], calls: 0, sizes: [], }
}

///|
pub impl @moonmime.Sink for Recorder with fn write(self, chunk) {
  for i = 0; i < chunk.length(); i = i + 1 {
    self.held.push(chunk[i])
  }
  self.calls = self.calls + 1
  self.sizes.push(chunk.length())
}

///|
pub extend Recorder with @moonmime.Sink::{write}

///|
/// The boundary a refusal names, for a writer whose errors also carry whatever
/// the sink raised.
fn refused_boundary(error : Error) -> String {
  match error {
    @moonmime.Boundary(got~) => got
    _ => "another error"
  }
}

///|
/// The bytes the sink has been handed so far.
fn Recorder::bytes(self : Recorder) -> Bytes {
  Bytes::from_array(self.held)
}

///|
/// A couple of parts that are not a form: an email's shape.
fn parts() -> Array[@moonmime.Part] {
  [
    { headers: [("content-type", "text/plain")], body: as_bytes("hola"), },
    {
      headers: [("content-type", "text/html"), ("content-id", "<two>")],
      body: as_bytes("<b>hola</b>"),
    },
  ]
}

///|
test "the streamed body is the one-shot body, byte for byte" {
  let one_shot = @moonmime.Multipart::new(parts(), boundary="b")
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  assert_eq(writer.boundary(), "b")
  for part in parts() {
    writer.begin_part(part.headers)
    writer.body(part.body)
  }
  writer.close()
  assert_eq(sink.bytes(), one_shot.body)
  assert_eq(writer.content_type(), one_shot.content_type())
}

///|
test "a boundary nobody gave is the one the one-shot writer chooses" {
  let one_shot = @moonmime.Multipart::new(parts())
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink)
  for part in parts() {
    writer.begin_part(part.headers)
    writer.body(part.body)
  }
  writer.close()
  assert_eq(writer.boundary(), one_shot.boundary)
  assert_eq(sink.bytes(), one_shot.body)
}

///|
test "a form-data writer announces a form" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(
    sink,
    boundary="b",
    kind=@moonmime.MultipartKind::FormData,
  )
  assert_eq(writer.content_type(), "multipart/form-data; boundary=b")
}

///|
test "a part reaches the sink as it is written" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  assert_eq(sink.calls, 0)
  writer.begin_part([("content-type", "text/plain")])
  // The delimiter, the header field and the empty line: nothing waits for the
  // part to end, which is what makes a body larger than memory possible.
  assert_eq(sink.calls, 3)
  assert_eq(sink.bytes(), as_bytes("--b\r\nContent-Type: text/plain\r\n\r\n"))
  writer.body(as_bytes("hola"))
  assert_eq(sink.calls, 4)
  assert_eq(sink.bytes().length(), 33 + 4)
  writer.close()
  assert_eq(
    sink.bytes(),
    as_bytes("--b\r\nContent-Type: text/plain\r\n\r\nhola\r\n--b--\r\n"),
  )
  assert_eq(sink.calls, 5)
}

///|
/// Closing a body that was already closed writes nothing more.
test "closing twice writes once" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  writer.begin_part([])
  writer.body(as_bytes("hola"))
  writer.close()
  let after_first = sink.bytes().length()
  writer.close()
  assert_eq(sink.bytes().length(), after_first)
}

///|
test "a body with no parts is the closing delimiter alone" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  writer.close()
  assert_eq(sink.bytes(), @moonmime.Multipart::new([], boundary="b").body)
}

///|
test "a part with no headers is still a part" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  writer.begin_part([])
  writer.body(as_bytes("bare"))
  writer.close()
  let read = @moonmime.multipart(sink.bytes()[:], "b")
  assert_eq(read.length(), 1)
  assert_eq(read[0].headers.length(), 0)
  assert_eq(read[0].body, b"bare")
}

///|
test "a body that holds the boundary is refused" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  writer.begin_part([])
  try writer.body(as_bytes("one--b--two")) catch {
    e => assert_eq(refused_boundary(e), "b")
  } noraise {
    _ => fail("a body holding its own delimiter was framed anyway")
  }
}

///|
test "a boundary split between two pieces is still refused" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  writer.begin_part([])
  writer.body(as_bytes("one-"))
  try writer.body(as_bytes("-b--two")) catch {
    e => assert_eq(refused_boundary(e), "b")
  } noraise {
    _ => fail("a delimiter split between two pieces went unnoticed")
  }
}

///|
test "a boundary in a header block is refused" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
  try writer.begin_part([("x-note", "one--b")]) catch {
    e => assert_eq(refused_boundary(e), "b")
  } noraise {
    _ => fail("a header holding the delimiter was written anyway")
  }
}

///|
test "a boundary that cannot delimit is refused" {
  try
    @moonmime.MultipartWriter::new(Recorder::new(), boundary="a b ") |> ignore
  catch {
    e => assert_eq(e, @moonmime.Boundary(got="a b "))
  } noraise {
    _ => fail("a boundary ending in a space was accepted")
  }
}

///|
test "panic: a body before a part begins stops the writer" {
  let writer = @moonmime.MultipartWriter::new(Recorder::new(), boundary="b")
  writer.body(as_bytes("hola"))
}

///|
test "what the writer frames is what the reader reads" {
  let sink = Recorder::new()
  let writer = @moonmime.MultipartWriter::new(sink, boundary="----edge")
  writer.begin_part([("content-disposition", "form-data; name=\"title\"")])
  writer.body(as_bytes("a report"))
  writer.begin_part([
    ("content-disposition", "form-data; name=\"file\"; filename=\"a.txt\""),
    ("content-type", "text/plain"),
  ])
  writer.body(as_bytes("line one"))
  writer.close()
  let form = @moonmime.formdata(sink.bytes()[:], "----edge")
  assert_eq(form.field("title"), Some("a report"))
  assert_eq(form.file("file").unwrap().filename, "a.txt")
  assert_eq(form.file("file").unwrap().content, b"line one")
}
