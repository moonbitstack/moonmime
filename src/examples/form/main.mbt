// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A multipart body as bytes. The page's helper: it turns a string literal
/// into the octets a request would carry.
fn body(text : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < text.length(); i = i + 1 {
    out.push((text.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// One body a browser sends for a form with two checkboxes sharing a name, a
/// text field, and a file with its own header.
let upload : String = "------WebKitFormBoundaryabc123\r\n" +
  "Content-Disposition: form-data; name=\"title\"\r\n" +
  "\r\n" +
  "a report\r\n" +
  "------WebKitFormBoundaryabc123\r\n" +
  "Content-Disposition: form-data; name=\"tags\"\r\n" +
  "\r\n" +
  "one\r\n" +
  "------WebKitFormBoundaryabc123\r\n" +
  "Content-Disposition: form-data; name=\"tags\"\r\n" +
  "\r\n" +
  "two\r\n" +
  "------WebKitFormBoundaryabc123\r\n" +
  "Content-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\n" +
  "Content-Type: text/plain\r\n" +
  "X-Checksum: abc\r\n" +
  "\r\n" +
  "line one\r\nline two\r\n" +
  "------WebKitFormBoundaryabc123--\r\n"

///|
/// The boundary is what follows the two leading dashes on each delimiter line.
let boundary : String = "----WebKitFormBoundaryabc123"

///|
/// Read the form, then drop one level to the raw parts it was built from.
fn main raise {
  // The typed view: text fields by name, files by name.
  let form = @moonmime.formdata(body(upload)[:], boundary)
  println(form.field("title").unwrap_or(""))
  // A set of checkboxes sends one name many times; `values` keeps them all.
  for tag in form.values("tags") {
    println(tag)
  }
  let file = form.file("file").unwrap()
  println(file.filename)
  println(file.content_type)
  // Content is held whole, minus the CRLF that belongs to the delimiter.
  println(file.size())
  println(file.header("x-checksum").unwrap_or(""))

  // The raw view: four parts, each with its own headers.
  let parts = @moonmime.multipart(body(upload)[:], boundary)
  println(parts.length())
  println(parts[0].disposition().unwrap().param("name").unwrap_or(""))
  println(parts[3].content_type().unwrap().essence)

  // A bound: two parts is fewer than this body has, so it is refused whole.
  try {
    let limited = @moonmime.formdata(
      body(upload)[:],
      boundary,
      limits=@moonmime.Limits::new(parts=2),
    )
    println(limited.is_empty())
  } catch {
    @moonmime.Parts(limit~) =>
      println("refused: more than " + limit.to_string() + " parts")
    _ => println("refused")
  }

  // `strict` turns a body that stops making sense into an error instead of
  // returning the parts read so far.
  let truncated = "------b\r\nContent-Disposition: form-data; name=\"a\"\r\n"
  ignore(@moonmime.formdata(body(truncated)[:], "----b", strict=true)) catch {
    @moonmime.Malformed(at~) => println("malformed at byte " + at.to_string())
    _ => println("refused")
  }
}
