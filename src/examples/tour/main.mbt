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
fn main raise {
  // Parse a media type and read its parameters back.
  let html = @moonmime.media_type("text/html; charset=utf-8")
  println(html.essence)
  println(html.param("charset").unwrap_or(""))

  // A filename implies a type; a type implies the filename people actually use.
  println(@moonmime.guess_type("tacos-al-pastor.png"))
  println(@moonmime.guess_extension("audio/mpeg").unwrap_or(""))

  // Name a download: plain ASCII stays quoted, a quote goes RFC 5987.
  println(@moonmime.content_disposition("menu.pdf"))
  println(@moonmime.content_disposition("receta \"de la abuela\".pdf"))

  // Split a multipart body — the shape email and forms share.
  let mail = body("--b\r\nContent-Type: text/plain\r\n\r\nhola\r\n--b--\r\n")
  let parts = @moonmime.multipart(mail[:], "b")
  println(parts[0].header("content-type").unwrap_or(""))
  println(parts[0].body.length())

  // The same bytes read as a form upload.
  let upload = body(
    "------edge\r\n" +
    "Content-Disposition: form-data; name=\"recipe\"\r\n" +
    "\r\n" +
    "chiles en nogada\r\n" +
    "------edge--\r\n",
  )
  let form = @moonmime.formdata(upload[:], "----edge")
  println(form.field("recipe").unwrap_or(""))
}
