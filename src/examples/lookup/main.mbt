// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Filenames and media types, read both ways: a name to its type, a type to
/// its usual extension, a `Content-Type` into its parts, and a download name
/// that leaves ASCII.
fn main {
  // A filename implies a media type. The last dot wins, so a compound
  // extension resolves on its tail, and case does not matter.
  println(@moonmime.guess_type("tacos-al-pastor.png"))
  println(@moonmime.guess_type("factura.PDF"))
  println(@moonmime.guess_type("archive.tar.gz"))

  // Something the registry has never heard of is just bytes.
  println(@moonmime.guess_type("name.unheard-of"))

  // A media type implies the extension people actually use for it. The
  // parameters are ignored, so it may be given with its charset.
  println(@moonmime.guess_extension("audio/mpeg").unwrap_or(""))
  println(@moonmime.guess_extension("text/plain; charset=utf-8").unwrap_or(""))

  // Parse a Content-Type into its essence and parameters. The essence is
  // lowercased; the parameter values keep their case.
  let mt = @moonmime.media_type("Text/HTML; charset=UTF-8")
  println(mt.essence)
  println(mt.type_())
  println(mt.subtype())
  println(mt.param("charset").unwrap_or(""))
  // It writes back the way it came in.
  println(mt.to_string())

  // Name a download: a plain ASCII name stays quoted; a quote in the name
  // pushes it to the RFC 5987 form, which a browser reads back whole.
  println(@moonmime.content_disposition("menu.pdf"))
  println(@moonmime.content_disposition("receta \"de la abuela\".pdf"))
}
