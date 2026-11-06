// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "parse a media type" {
  let mt = @moonmime.media_type("text/plain; charset=utf-8")
  assert_eq(mt.essence, "text/plain")
  assert_eq(mt.param("charset"), Some("utf-8"))
  assert_eq(mt.type_(), "text")
  assert_eq(mt.subtype(), "plain")
  assert_eq(mt.param("absent"), None)
}

///|
test "parameters come quoted or bare" {
  let mt = @moonmime.media_type(
    "multipart/form-data; boundary=----edge; charset=\"utf 8\"",
  )
  assert_eq(mt.param("boundary"), Some("----edge"))
  assert_eq(mt.param("charset"), Some("utf 8"))
}

///|
test "essence and names are case-insensitive" {
  assert_eq(@moonmime.media_type("TEXT/PLAIN").essence, "text/plain")
  assert_eq(
    @moonmime.media_type("Application/JSON").essence,
    "application/json",
  )
  assert_eq(
    @moonmime.media_type("text/plain; Charset=UTF-8").param("charset"),
    Some("UTF-8"),
  )
}

///|
test "a foreign value is empty" {
  assert_eq(@moonmime.media_type("").essence, "")
  assert_eq(@moonmime.media_type("").subtype(), "")
  assert_eq(@moonmime.media_type("text").subtype(), "")
  assert_eq(@moonmime.media_type("text/plain").params.length(), 0)
}

///|
test "a malformed parameter is dropped" {
  assert_eq(@moonmime.media_type("text/plain; noequals").params.length(), 0)
  assert_eq(@moonmime.media_type("text/plain; =value").param(""), Some("value"))
}

///|
test "round trips" {
  assert_eq(
    @moonmime.media_type("text/plain; charset=utf-8").to_string(),
    "text/plain; charset=utf-8",
  )
  assert_eq(
    @moonmime.media_type("multipart/form-data; boundary=\"a b\"").to_string(),
    "multipart/form-data; boundary=\"a b\"",
  )
  // A value parsed bare but not a token goes back quoted.
  assert_eq(
    @moonmime.media_type("multipart/form-data; boundary=a b").to_string(),
    "multipart/form-data; boundary=\"a b\"",
  )
}

///|
test "a quoted value keeps its escaped quote" {
  let mt = @moonmime.media_type("text/plain; x=\"a\\\"b\"")
  assert_eq(mt.param("x"), Some("a\"b"))
  assert_eq(mt.to_string(), "text/plain; x=\"a\\\"b\"")
}

///|
test "the strict reader follows the standard" {
  // The first of two parameters with the same name wins, as the standard has it.
  let mt = @moonmime.MediaType::parse(
    "Text/HTML; charset=\"utf-8\"; charset=latin1",
  ).unwrap()
  assert_eq(mt.essence, "text/html")
  assert_eq(mt.param("charset"), Some("utf-8"))
  // Whitespace around the value is part of a bare value, not of the name.
  assert_eq(
    @moonmime.MediaType::parse(" text/plain ; charset=utf-8 ")
    .unwrap()
    .to_string(),
    "text/plain; charset=utf-8",
  )
}

///|
test "the strict reader refuses a value that is not a media type" {
  for
    value in [
      "", "text", "/plain", "text/", "text /plain", "text/plain, text/html",
    ] {
    let parsed = @moonmime.MediaType::parse(value)
    assert_true(parsed is None)
  }
  // A trailing `;` is not a media type string, but it parses as one.
  assert_eq(
    @moonmime.MediaType::parse("text/plain;").unwrap().essence,
    "text/plain",
  )
}

///|
test "the strict reader drops a parameter it cannot carry" {
  // A NUL cannot be written back into a quoted string, so the parameter goes.
  let mt = @moonmime.MediaType::parse(
    "text/plain; x=\"a\u{0000}b\"; charset=utf-8",
  ).unwrap()
  assert_eq(mt.param("x"), None)
  assert_eq(mt.param("charset"), Some("utf-8"))
  // The lenient reader keeps both, which is the difference between the two.
  assert_eq(
    @moonmime.media_type("text/plain; x=\"a\u{0000}b\"").params.length(),
    1,
  )
}
