// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "an extension names a media type" {
  let cases = [
    ("factura.pdf", "application/pdf"),
    ("foto.JPEG", "image/jpeg"),
    ("page.html", "text/html"),
    ("notes.md", "text/markdown"),
    ("data.json", "application/json"),
    ("config.yaml", "application/yaml"),
    ("archive.zip", "application/zip"),
    ("module.wasm", "application/wasm"),
    ("icon.svg", "image/svg+xml"),
    ("mariachi.mp3", "audio/mpeg"),
    ("clip.mp4", "video/mp4"),
  ]
  for case in cases {
    let (name, want) = case
    assert_eq(@moonmime.guess_type(name[:]), want)
  }
}

///|
test "an unknown extension is bytes" {
  for name in ["a.unheard-of", "no-extension", "", ".", "trailing."] {
    assert_eq(@moonmime.guess_type(name[:]), @moonmime.fallback)
  }
  assert_eq(@moonmime.fallback, "application/octet-stream")
  // The last dot wins, so a compound extension resolves on its tail.
  assert_eq(@moonmime.guess_type("archive.tar.gz"[:]), "application/gzip")
  assert_eq(@moonmime.guess_type("a.b.c.png"[:]), "image/png")
}

///|
test "a type names its common extension" {
  assert_eq(@moonmime.guess_extension("text/html"), Some(".html"))
  assert_eq(@moonmime.guess_extension("image/jpeg"), Some(".jpg"))
  assert_eq(@moonmime.guess_extension("application/json"), Some(".json"))
  assert_eq(@moonmime.guess_extension("application/unheard-of"), None)
  // Parameters are ignored.
  assert_eq(
    @moonmime.guess_extension("text/plain; charset=utf-8"),
    Some(".txt"),
  )
}
