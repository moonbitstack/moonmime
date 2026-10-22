// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A multipart body exactly as a browser writes one.
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
test "a multipart body from a browser" {
  let form = @moonmime.formdata(body(upload)[:], "----WebKitFormBoundaryabc123")
  assert_eq(form.field("title"), Some("a report"))
  assert_eq(form.values("tags"), ["one", "two"])
  let file = form.file("file").unwrap()
  assert_eq(file.filename, "notes.txt")
  assert_eq(file.content_type, "text/plain")
  // The content keeps its own line breaks and loses only the trailing CRLF that
  // belongs to the delimiter.
  assert_eq(file.content, b"line one\r\nline two")
  assert_eq(file.size(), 18)
  assert_eq(file.header("x-checksum"), Some("abc"))
  assert_eq(file.header("content-type"), Some("text/plain"))
  assert_eq(file.header("nonesuch"), None)
  assert_eq(form.uploads().length(), 1)
  assert_eq(form.entries().length(), 3)
}

///|
test "a form built from fields and files reads like a parsed one" {
  let fields : Array[@moonmime.Field] = [
    { name: "tag", value: "a", },
    { name: "tag", value: "b", },
  ]
  let form = @moonmime.Form::new(fields~)
  assert_eq(form.values("tag"), ["a", "b"])
  assert_eq(form.field("tag"), Some("a"))
  assert_eq(form.uploads().length(), 0)
  fields.push({ name: "late", value: "x", })
  assert_eq(form.field("late"), None)
  assert_true(@moonmime.Form::new().is_empty())
  let parsed = @moonmime.formdata(
    body(upload)[:],
    "----WebKitFormBoundaryabc123",
  )
  let rebuilt = @moonmime.Form::new(
    fields=parsed.entries(),
    files=parsed.uploads(),
  )
  assert_eq(rebuilt.entries(), parsed.entries())
  assert_eq(rebuilt.uploads(), parsed.uploads())
}

///|
test "limits are enforced" {
  let few : @moonmime.Limits = { parts: 2, part_size: 1000, }
  try
    @moonmime.formdata(
      body(upload)[:],
      "----WebKitFormBoundaryabc123",
      limits=few,
    )
    |> ignore
  catch {
    e => assert_eq(e, @moonmime.Parts(limit=2))
  } noraise {
    _ => fail("four parts passed a limit of two")
  }
}

///|
test "a malformed multipart body" {
  let broken = "------b\r\nContent-Disposition: form-data; name=\"a\"\r\n"
  assert_true(@moonmime.formdata(body(broken)[:], "----b").is_empty())
  assert_true(@moonmime.formdata(body(upload)[:], "----nothing").is_empty())
  assert_true(@moonmime.formdata(body("")[:], "----b").is_empty())
  // A part with no name still parses, under the empty name.
  let unnamed = "------b\r\nContent-Disposition: form-data\r\n\r\nvalue\r\n------b--\r\n"
  assert_eq(
    @moonmime.formdata(body(unnamed)[:], "----b").field(""),
    Some("value"),
  )
}

///|
test "strict decides what a body that stops making sense means" {
  let broken = "------b\r\nContent-Disposition: form-data; name=\"a\"\r\n"
  try
    @moonmime.formdata(body(broken)[:], "----b", strict=true) |> ignore
  catch {
    e => assert_eq(e, @moonmime.Malformed(at=9))
  } noraise {
    _ => fail("a truncated body passed in strict mode")
  }
}
