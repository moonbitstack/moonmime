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
test "dispatching on the content type" {
  let ct = "multipart/form-data; boundary=----WebKitFormBoundaryabc123"
  assert_eq(
    @moonmime.form(body(upload)[:], ct[:]).field("title"),
    Some("a report"),
  )
  // Anything else carried no form, which is an answer rather than a failure.
  assert_true(
    @moonmime.form(body("{\"a\":1}")[:], "application/json").is_empty(),
  )
  assert_true(@moonmime.form(body("x")[:], "").is_empty())
  // A multipart type with no boundary names no parts.
  assert_true(@moonmime.form(body(upload)[:], "multipart/form-data").is_empty())
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
  try
    @moonmime.form(body("{\"a\":1}")[:], "application/json", strict=true)
    |> ignore
  catch {
    e => assert_eq(e, @moonmime.NotAForm(content_type="application/json"))
  } noraise {
    _ => fail("a JSON body passed as a form in strict mode")
  }
}
