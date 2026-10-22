// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "parse a disposition" {
  let d = @moonmime.Disposition::parse(
    "form-data; name=\"file\"; filename=\"a.txt\"",
  )
  assert_eq(d.kind, "form-data")
  assert_eq(d.param("name"), Some("file"))
  assert_eq(d.filename(), Some("a.txt"))
}

///|
test "filename star wins over filename" {
  let d = @moonmime.Disposition::parse(
    "attachment; filename=\"fallback.txt\"; filename*=utf-8''r%C3%A9sum%C3%A9.txt",
  )
  assert_eq(d.filename(), Some("résumé.txt"))
}

///|
test "a non-utf-8 filename star falls back" {
  let d = @moonmime.Disposition::parse(
    "attachment; filename=\"plain.txt\"; filename*=iso-8859-1''x",
  )
  assert_eq(d.filename(), Some("plain.txt"))
}

///|
test "a plain name is quoted as it is" {
  assert_eq(
    @moonmime.content_disposition("report.pdf"[:]),
    "attachment; filename=\"report.pdf\"",
  )
  assert_eq(
    @moonmime.content_disposition("report.pdf"[:], inline=true),
    "inline; filename=\"report.pdf\"",
  )
}

///|
test "a name that cannot be quoted goes out as filename star" {
  for name in ["résumé.pdf", "say \"hi\".txt", "one\ntwo.txt"] {
    let got = @moonmime.content_disposition(name[:])
    assert_true(got.contains("filename*=utf-8''"))
    assert_false(got.contains("filename=\""))
  }
  // A space and a path separator stay quoted: they are ASCII and break nothing.
  assert_eq(
    @moonmime.content_disposition("my report.pdf"[:]),
    "attachment; filename=\"my report.pdf\"",
  )
  assert_eq(
    @moonmime.content_disposition("a/b.txt"[:]),
    "attachment; filename=\"a/b.txt\"",
  )
}
