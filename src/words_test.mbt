// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "decode_words reads a base64 word" {
  inspect(@moonmime.decode_words("=?utf-8?B?Q2Fmw6k=?="), content="Café")
}

///|
test "decode_words reads a Q word" {
  inspect(@moonmime.decode_words("=?utf-8?Q?Caf=C3=A9?="), content="Café")
}

///|
test "decode_words joins adjacent words without the folding space" {
  inspect(
    @moonmime.decode_words("=?utf-8?B?SGVsbG8=?= =?utf-8?B?V29ybGQ=?="),
    content="HelloWorld",
  )
}

///|
test "decode_words keeps surrounding text and its spaces" {
  inspect(
    @moonmime.decode_words("Hi =?utf-8?B?Q2Fmw6k=?= there"),
    content="Hi Café there",
  )
}

///|
test "decode_words leaves a lone =? as ordinary text" {
  inspect(@moonmime.decode_words("not =? a word"), content="not =? a word")
}

///|
test "encode_words keeps printable ascii plain" {
  inspect(@moonmime.encode_words("Hello there"), content="Hello there")
}

///|
test "encode_word round trips non-ascii with base64" {
  let word = @moonmime.encode_word("Café") catch { _ => "" }
  inspect(@moonmime.decode_words(word[:]), content="Café")
}

///|
test "encode_word round trips non-ascii with quoted-printable" {
  let word = @moonmime.encode_word(
    "Café ☕",
    encoding=@moonmime.WordEncoding::QuotedPrintable,
  ) catch {
    _ => ""
  }
  inspect(@moonmime.decode_words(word[:]), content="Café ☕")
}

///|
test "encode_words round trips a long non-ascii subject" {
  let text = "Grüße aus München — ein längerer Betreff mit Umlauten und mehr"
  let encoded = @moonmime.encode_words(text) catch { _ => "" }
  inspect(@moonmime.decode_words(encoded[:]), content=text)
}

///|
test "encode_words never splits a multi-octet character" {
  // Each 'é' is two octets, so a 45-octet Base64 slice lands mid-character
  // unless the slicer backs the boundary up to a lead octet.
  let b = StringBuilder()
  for _i in 0..<40 {
    b.write_char('é')
  }
  let text = b.to_string()
  let encoded = @moonmime.encode_words(text) catch { _ => "" }
  inspect(@moonmime.decode_words(encoded[:]), content=text)
}
