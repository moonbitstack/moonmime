---
name: moonmime
description: MIME for MoonBit — media types and their parameters, the filename-to-type registry, Content-Disposition, and multipart / multipart/form-data bodies. Use it to read a Content-Type header, guess a media type from a filename, build a download header, or split a multipart or form upload.
---

# moonmime

Add it and import the package you need:

```sh
moon add moonbitstack/moonmime
```

```moonbit
import {
  "moonbitstack/moonmime",
}
```

## Read a media type

`media_type` keeps what it can; `MediaType::parse` refuses anything the MIME
Sniffing standard would not read.

```moonbit
let mt = @moonmime.media_type("Text/HTML; charset=UTF-8")
assert_eq(mt.essence, "text/html")
assert_eq(mt.param("charset").unwrap_or(""), "UTF-8")
let strict = @moonmime.MediaType::parse("text/html; charset=\"utf-8\"")
assert_eq(strict.unwrap().essence, "text/html")
```

## Guess from a filename

`guess_type` takes the last extension and answers `fallback`
(`application/octet-stream`) for a name it has not heard; `guess_extension`
goes the other way and ignores parameters.

```moonbit
assert_eq(@moonmime.guess_type("archive.tar.gz"), "application/gzip")
assert_eq(@moonmime.guess_extension("image/jpeg"), Some(".jpg"))
assert_eq(@moonmime.guess_type("no-extension"), @moonmime.fallback)
```

## Split a body, then read it as a form

A part is a file when its `Content-Disposition` carries a `filename`; `formdata`
turns that into `field`, `values`, and `file`.

```moonbit
let boundary = "----edge"
let body = b"------edge\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n------edge--\r\n"
let parts = @moonmime.multipart(body[:], boundary)
assert_eq(parts.length(), 1)
let form = @moonmime.formdata(body[:], boundary)
assert_eq(form.field("title"), Some("hello"))
```

## The rules that catch people out

- `body` is `String` (the raw bytes as a string) and `boundary` is the delimiter
  without its leading dashes; both are plain `String` / `StringView` in, so keep
  the bytes intact rather than re-encoding them.
- `multipart` and `formdata` are bounded by a `Limits` — a thousand parts of a
  megabyte each by default — and refuse a body over the bound whole rather than
  truncate it; pass a tighter `Limits` when the request says so.
- `media_type` is the forgiving reader and `MediaType::parse` is the strict one;
  a header that decides what a file is should be read strictly.
- Quoted-printable and encoded words are in `moonbitstack/moonmime/qp` and the
  `encode_words` / `decode_words` of the root package.
