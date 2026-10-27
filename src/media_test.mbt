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
