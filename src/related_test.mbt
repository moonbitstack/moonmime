// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn utf8(value : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < value.length(); i = i + 1 {
    out.push((value.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// The parts of a related body: a root and the picture it embeds.
fn related_parts() -> Array[@moonmime.Part] {
  [
    {
      headers: [("content-id", "<root>"), ("content-type", "text/html")],
      body: utf8("<img src=\"cid:logo\">"),
    },
    {
      headers: [("content-id", "<logo>"), ("content-type", "image/png")],
      body: b"\x89PNG",
    },
  ]
}

///|
test "a related body names its type, its start and its start-info" {
  let body = @moonmime.Related::new(
    related_parts(),
    boundary="b",
    type_="multipart/alternative",
    start="<root>",
    start_info="text/html",
  )
  assert_eq(
    body.content_type(),
    "multipart/related; boundary=b; type=\"multipart/alternative\"; start=\"<root>\"; start-info=\"text/html\"",
  )
}

///|
test "a parameter that was not given is not written" {
  let body = @moonmime.Related::new(related_parts(), boundary="b")
  assert_eq(body.content_type(), "multipart/related; boundary=b")
}

///|
test "the parameters come back off the header" {
  let written = @moonmime.Related::new(
    related_parts(),
    boundary="b",
    type_="text/html",
    start="<root>",
    start_info="charset=utf-8",
  )
  let read = @moonmime.related(written.content_type(), written.body()) catch {
    e => fail("a body this library wrote was refused: \{e.to_repr()}")
  }
  assert_eq(read.type_, "text/html")
  assert_eq(read.start, "<root>")
  assert_eq(read.start_info, "charset=utf-8")
  assert_eq(read.boundary, "b")
  assert_eq(read.parts.length(), 2)
  assert_eq(read.parts[0].body, utf8("<img src=\"cid:logo\">"))
}

///|
test "the root is the part start names" {
  let written = @moonmime.Related::new(
    related_parts(),
    boundary="b",
    start="<logo>",
  )
  let read = @moonmime.related(written.content_type(), written.body())
  let root = read.root().unwrap()
  assert_eq(root.content_type().unwrap().essence, "image/png")
  assert_eq(root.body, b"\x89PNG")
  assert_eq(root.content_id(), Some("logo"))
}

///|
test "a start without its angle brackets names the same part" {
  let written = @moonmime.Related::new(
    related_parts(),
    boundary="b",
    start="logo",
  )
  let read = @moonmime.related(written.content_type(), written.body())
  assert_eq(read.root().unwrap().content_type().unwrap().essence, "image/png")
}

///|
test "the first part is the root when the header names none" {
  let written = @moonmime.Related::new(related_parts(), boundary="b")
  let read = @moonmime.related(written.content_type(), written.body())
  assert_eq(read.root().unwrap().content_type().unwrap().essence, "text/html")
}

///|
test "a start that names nothing leaves the root unknown" {
  let written = @moonmime.Related::new(
    related_parts(),
    boundary="b",
    start="<gone>",
  )
  let read = @moonmime.related(written.content_type(), written.body())
  assert_eq(read.root() is None, true)
}

///|
test "a body with no parts has no root" {
  let written = @moonmime.Related::new([], boundary="b")
  let read = @moonmime.related(written.content_type(), written.body())
  assert_eq(read.root() is None, true)
}

///|
test "related framing is the framing every multipart subtype shares" {
  let written = @moonmime.Related::new(
    related_parts(),
    boundary="b",
    type_="text/html",
  )
  assert_eq(
    written.body(),
    @moonmime.Multipart::new(related_parts(), boundary="b").body,
  )
  let parts = @moonmime.multipart(written.body()[:], "b")
  assert_eq(parts.length(), 2)
}

///|
test "a boundary nobody gave is generated and proven absent" {
  let written = @moonmime.Related::new(related_parts(), type_="text/html")
  assert_eq(written.boundary, "----moonmime")
  assert_eq(
    @moonmime.multipart(written.body()[:], written.boundary).length(),
    2,
  )
}

///|
test "a header that is not related is refused" {
  try @moonmime.related("text/plain", b"hola") |> ignore catch {
    e => assert_eq(e, @moonmime.NotRelated(content_type="text/plain"))
  } noraise {
    _ => fail("a text/plain header was read as a related body")
  }
}

///|
test "a related header with no boundary is refused" {
  try
    @moonmime.related("multipart/related; type=\"text/html\"", b"") |> ignore
  catch {
    e => assert_eq(e, @moonmime.Boundary(got=""))
  } noraise {
    _ => fail("a related header without a boundary was accepted")
  }
}

///|
test "a body that holds more parts than its bound is refused" {
  let written = @moonmime.Related::new(related_parts(), boundary="b")
  try
    @moonmime.related(
      written.content_type(),
      written.body(),
      limits=@moonmime.Limits::new(parts=1),
    )
    |> ignore
  catch {
    e => assert_eq(e, @moonmime.Parts(limit=1))
  } noraise {
    _ => fail("two parts passed a limit of one")
  }
}

///|
test "a part's Content-ID keeps the address and drops the brackets" {
  let part : @moonmime.Part = {
    headers: [("content-id", "  <20260101.photo@example>  ")],
    body: b"",
  }
  assert_eq(part.content_id(), Some("20260101.photo@example"))
  let head : @moonmime.PartHead = { headers: part.headers, }
  assert_eq(head.content_id(), Some("20260101.photo@example"))
  assert_eq(({ headers: [], } : @moonmime.PartHead).content_id() is None, true)
}
