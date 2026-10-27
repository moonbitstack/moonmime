// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn body(text : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < text.length(); i = i + 1 {
    out.push((text.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A `multipart/mixed` body as an email client writes one, with parts that are
/// text and not forms at all.
let email : String = "--b\r\n" +
  "Content-Type: text/plain\r\n" +
  "\r\n" +
  "hola\r\n" +
  "--b\r\n" +
  "Content-Type: text/html\r\n" +
  "\r\n" +
  "<b>hola</b>\r\n" +
  "--b--\r\n"

///|
test "a multipart body splits into parts" {
  let parts = @moonmime.multipart(body(email)[:], "b")
  assert_eq(parts.length(), 2)
  assert_eq(parts[0].header("content-type"), Some("text/plain"))
  assert_eq(parts[0].body, b"hola")
  assert_eq(parts[0].content_type().unwrap().essence, "text/plain")
  assert_eq(parts[1].header("content-type"), Some("text/html"))
  assert_eq(parts[1].body, b"<b>hola</b>")
  assert_eq(parts[1].content_type().unwrap().essence, "text/html")
  assert_eq(parts[0].disposition(), None)
}

///|
test "a preamble and epilogue are dropped" {
  let padded = "this is a preamble\r\n--b\r\n" +
    "Content-Type: text/plain\r\n\r\nhi\r\n--b--\r\nthis is an epilogue"
  let parts = @moonmime.multipart(body(padded)[:], "b")
  assert_eq(parts.length(), 1)
  assert_eq(parts[0].body, b"hi")
}

///|
test "a part count over the bound is refused" {
  let few : @moonmime.Limits = { parts: 1, part_size: 1000, }
  try @moonmime.multipart(body(email)[:], "b", limits=few) |> ignore catch {
    e => assert_eq(e, @moonmime.Parts(limit=1))
  } noraise {
    _ => fail("two parts passed a limit of one")
  }
}

///|
test "a part size over the bound is refused" {
  let small : @moonmime.Limits = { parts: 10, part_size: 2, }
  try @moonmime.multipart(body(email)[:], "b", limits=small) |> ignore catch {
    e => assert_eq(e, @moonmime.Part(limit=2, got=4))
  } noraise {
    _ => fail("a four-byte part passed a limit of two")
  }
}

///|
test "strict refuses a body that stops making sense" {
  let broken = "--b\r\nContent-Type: text/plain\r\n"
  assert_eq(@moonmime.multipart(body(broken)[:], "b").length(), 0)
  try @moonmime.multipart(body(broken)[:], "b", strict=true) |> ignore catch {
    e => assert_eq(e, @moonmime.Malformed(at=5))
  } noraise {
    _ => fail("a truncated body passed in strict mode")
  }
}

///|
test "the two forms of the bound agree" {
  assert_eq(@moonmime.Limits::new(parts=2), { ..@moonmime.limits, parts: 2, })
  assert_eq(@moonmime.Limits::new(), @moonmime.limits)
  assert_eq(
    @moonmime.Limits::new(parts=8).part_size,
    @moonmime.limits.part_size,
  )
  assert_eq(@moonmime.limits.parts, 1000)
  assert_eq(@moonmime.limits.part_size, 1 << 20)
}
