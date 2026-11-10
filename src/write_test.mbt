// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "a form goes out the way a browser reads one" {
  let form = @moonmime.Form::new(
    fields=[
      { name: "title", value: "a report", },
      { name: "tags", value: "one", },
      { name: "tags", value: "two", },
    ],
    files=[
      {
        name: "file",
        filename: "notes.txt",
        content_type: "text/plain",
        content: body("line one"),
        headers: [("x-checksum", "abc")],
      },
    ],
  )
  let written = form.encode(boundary="----edge")
  assert_eq(written.content_type(), "multipart/form-data; boundary=----edge")
  assert_eq(written.boundary, "----edge")
  assert_eq(
    written.body,
    body(
      "------edge\r\n" +
      "Content-Disposition: form-data; name=\"title\"\r\n" +
      "\r\n" +
      "a report\r\n" +
      "------edge\r\n" +
      "Content-Disposition: form-data; name=\"tags\"\r\n" +
      "\r\n" +
      "one\r\n" +
      "------edge\r\n" +
      "Content-Disposition: form-data; name=\"tags\"\r\n" +
      "\r\n" +
      "two\r\n" +
      "------edge\r\n" +
      "Content-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\n" +
      "Content-Type: text/plain\r\n" +
      "X-Checksum: abc\r\n" +
      "\r\n" +
      "line one\r\n" +
      "------edge--\r\n",
    ),
  )
  // Every octet of it reads back as what went in.
  let read = @moonmime.formdata(written.body[:], written.boundary)
  assert_eq(read.field("title"), Some("a report"))
  assert_eq(read.values("tags"), ["one", "two"])
  let file = read.file("file").unwrap()
  assert_eq(file.filename, "notes.txt")
  assert_eq(file.content_type, "text/plain")
  assert_eq(file.content, body("line one"))
  assert_eq(file.header("x-checksum"), Some("abc"))
}

///|
test "the boundary is a function of the parts" {
  let form = @moonmime.Form::new(fields=[{ name: "a", value: "1", }])
  let first = form.encode()
  let second = form.encode()
  assert_eq(first.boundary, "----moonmime")
  assert_eq(first.body, second.body)
  assert_eq(first.content_type(), "multipart/form-data; boundary=----moonmime")
  assert_eq(
    @moonmime.formdata(first.body[:], first.boundary).field("a"),
    Some("1"),
  )
}

///|
test "a boundary the parts already hold is stepped past" {
  let form = @moonmime.Form::new(fields=[
    { name: "text", value: "------moonmime is written here", },
  ])
  let written = form.encode()
  assert_eq(written.boundary, "----moonmime1")
  assert_eq(
    @moonmime.formdata(written.body[:], written.boundary).field("text"),
    Some("------moonmime is written here"),
  )
}

///|
test "a nested body is framed without its parent's delimiter" {
  let inner = @moonmime.Form::new(fields=[{ name: "a", value: "1", }]).encode()
  let outer = @moonmime.Multipart::new([
    { headers: [("content-type", inner.content_type())], body: inner.body, },
  ])
  assert_eq(inner.boundary, "----moonmime")
  assert_true(outer.boundary != inner.boundary)
  let parts = @moonmime.multipart(outer.body[:], outer.boundary)
  assert_eq(parts.length(), 1)
  assert_eq(
    parts[0].content_type().unwrap().param("boundary"),
    Some(inner.boundary),
  )
  assert_eq(parts[0].body, inner.body)
  assert_eq(
    @moonmime.formdata(parts[0].body[:], inner.boundary).field("a"),
    Some("1"),
  )
}

///|
test "a boundary that cannot delimit the body is refused" {
  let form = @moonmime.Form::new(fields=[{ name: "a", value: "1", }])
  for bad in ["", "----a b ", "----a\"b", "----a:b\r\n", "--" + "_".repeat(70)] {
    try form.encode(boundary=bad) |> ignore catch {
      e => assert_eq(e, @moonmime.Boundary(got=bad))
    } noraise {
      _ => fail("refused to refuse the boundary " + bad)
    }
  }
  // A boundary that is legal but already inside the content is refused too:
  // a receiver would split on it and hand back different data.
  let colliding = @moonmime.Form::new(fields=[
    { name: "a", value: "------edge", },
  ])
  try colliding.encode(boundary="----edge") |> ignore catch {
    e => assert_eq(e, @moonmime.Boundary(got="----edge"))
  } noraise {
    _ => fail("wrote a boundary that occurs inside a part")
  }
}

///|
test "a boundary with a space goes out quoted" {
  let written = @moonmime.Multipart::new(
    [{ headers: [("content-type", "text/plain")], body: body("hi"), }],
    boundary="----a b",
  )
  assert_eq(written.content_type(), "multipart/mixed; boundary=\"----a b\"")
  let read = @moonmime.media_type(written.content_type())
  assert_eq(read.param("boundary"), Some("----a b"))
  let parts = @moonmime.multipart(
    written.body[:],
    read.param("boundary").unwrap(),
  )
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].body, body("hi"))
}

///|
test "a filename that leaves ASCII is named in the extended form" {
  let form = @moonmime.Form::new(files=[
    {
      name: "file",
      filename: "résumé \"final\".pdf",
      content_type: "application/pdf",
      content: body("%PDF"),
      headers: [],
    },
  ])
  let written = form.encode(boundary="----edge")
  let header = @moonmime.Disposition::parse(
    @moonmime.multipart(written.body[:], written.boundary)[0]
    .header("content-disposition")
    .unwrap(),
  )
  assert_eq(header.kind, "form-data")
  assert_eq(header.param("name"), Some("file"))
  assert_eq(
    header.param("filename*"),
    Some("utf-8''r%C3%A9sum%C3%A9%20%22final%22.pdf"),
  )
  assert_eq(header.param("filename"), None)
  assert_eq(header.filename(), Some("résumé \"final\".pdf"))
  assert_eq(
    @moonmime.formdata(written.body[:], written.boundary).file("file").unwrap().filename,
    "résumé \"final\".pdf",
  )
}

///|
test "a name that needs quoting stays one parameter" {
  let form = @moonmime.Form::new(fields=[{ name: "a \"b\" \\ c", value: "1", }])
  let written = form.encode(boundary="----edge")
  let disposition = @moonmime.Disposition::parse(
    @moonmime.multipart(written.body[:], written.boundary)[0]
    .header("content-disposition")
    .unwrap(),
  )
  assert_eq(disposition.param("name"), Some("a \"b\" \\ c"))
  assert_eq(
    @moonmime.formdata(written.body[:], written.boundary).field("a \"b\" \\ c"),
    Some("1"),
  )
}

///|
test "a value that looks like a header stays a value" {
  let value = "Content-Type: text/html\r\n\r\n--not-a-delimiter"
  let written = @moonmime.Form::new(fields=[{ name: "v", value, }]).encode(
    boundary="----edge",
  )
  assert_eq(
    @moonmime.formdata(written.body[:], written.boundary).field("v"),
    Some(value),
  )
}

///|
test "an empty form is still a body" {
  let written = @moonmime.Form::new().encode(boundary="----edge")
  assert_eq(written.body, body("------edge--\r\n"))
  assert_eq(@moonmime.multipart(written.body[:], written.boundary).length(), 0)
  assert_true(@moonmime.formdata(written.body[:], written.boundary).is_empty())
}

///|
test "a part with no headers and no content" {
  let written = @moonmime.Multipart::new(
    [{ headers: [], body: b"", }, { headers: [("x-a", "1")], body: b"", }],
    boundary="----edge",
  )
  let parts = @moonmime.multipart(written.body[:], written.boundary)
  assert_eq(parts.length(), 2)
  assert_eq(parts[0].headers, [])
  assert_eq(parts[0].body, b"")
  assert_eq(parts[1].header("x-a"), Some("1"))
  assert_eq(parts[1].body, b"")
}

///|
test "a mixed body keeps its parts and their order" {
  let written = @moonmime.Multipart::new([
    { headers: [("content-type", "text/plain")], body: body("hola"), },
    { headers: [("content-type", "text/html")], body: body("<b>hola</b>"), },
  ])
  assert_eq(written.kind, @moonmime.Mixed)
  assert_eq(written.kind.code(), "mixed")
  assert_eq(@moonmime.FormData.code(), "form-data")
  assert_eq(written.content_type(), "multipart/mixed; boundary=----moonmime")
  let parts = @moonmime.multipart(written.body[:], written.boundary)
  assert_eq(parts.length(), 2)
  assert_eq(parts[0].body, body("hola"))
  assert_eq(parts[1].content_type().unwrap().essence, "text/html")
  assert_eq(parts[1].body, body("<b>hola</b>"))
}

///|
test "a parsed body goes back out as it came" {
  let parsed = @moonmime.formdata(
    body(
      "------WebKitFormBoundaryabc123\r\n" +
      "Content-Disposition: form-data; name=\"title\"\r\n" +
      "\r\n" +
      "a report\r\n" +
      "------WebKitFormBoundaryabc123\r\n" +
      "Content-Disposition: form-data; name=\"file\"; filename=\"notes.txt\"\r\n" +
      "Content-Type: text/plain\r\n" +
      "X-Checksum: abc\r\n" +
      "\r\n" +
      "line one\r\nline two\r\n" +
      "------WebKitFormBoundaryabc123--\r\n",
    )[:],
    "----WebKitFormBoundaryabc123",
  )
  let again = @moonmime.Form::new(
    fields=parsed.entries(),
    files=parsed.uploads(),
  ).encode(boundary="----WebKitFormBoundaryabc123")
  let read = @moonmime.formdata(again.body[:], again.boundary)
  assert_eq(read.entries(), parsed.entries())
  assert_eq(read.uploads(), parsed.uploads())
  // The file part has one disposition, not the parsed one and a written one.
  assert_eq(
    @moonmime.multipart(again.body[:], again.boundary)[1].headers.length(),
    3,
  )
}

///|
test "a folded header is unfolded" {
  let folded = "------edge\r\n" +
    "Content-Disposition: form-data; name=\"file\";\r\n" +
    " filename=\"resume.txt\"\r\n" +
    "Content-Type: text/plain\r\n" +
    "\r\n" +
    "hi\r\n" +
    "------edge--\r\n"
  let form = @moonmime.formdata(body(folded)[:], "----edge")
  let file = form.file("file").unwrap()
  assert_eq(file.filename, "resume.txt")
  assert_eq(file.content, body("hi"))
  // A fold after a bare LF is the same break.
  let bare = "------edge\r\n" +
    "Content-Disposition: form-data;\n name=\"file\"; filename=\"a.txt\"\r\n" +
    "\r\n" +
    "hi\r\n" +
    "------edge--\r\n"
  assert_eq(
    @moonmime.formdata(body(bare)[:], "----edge").file("file").unwrap().filename,
    "a.txt",
  )
}

///|
test "a part with no header field at all" {
  // A writer that has nothing to say about a part still delimits it, and the
  // empty line that ends the header block is the first thing after the
  // delimiter.
  let raw = "--b\r\n\r\nno headers here\r\n--b--\r\n"
  let parts = @moonmime.multipart(body(raw)[:], "b")
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].headers, [])
  assert_eq(parts[0].content_type(), None)
  assert_eq(parts[0].body, body("no headers here"))
  let written = @moonmime.Multipart::new(
    [{ headers: [], body: body("no headers here"), }],
    boundary="b",
  )
  assert_eq(written.body, body(raw))
}
