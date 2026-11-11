---
name: moonmime
description: "MIME for MoonBit — media types and their parameters, the filename-to-type registry, Content-Disposition, and multipart, multipart/form-data and multipart/related bodies, read whole or a piece at a time and written the same way. Use it to read a Content-Type header, guess a media type from a filename, build a download header, split a multipart or form upload, stream one as it arrives, write one a part at a time, or find the root of a related body."
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

## Write a form

`Form::encode` frames the parts a browser would send and hands back the octets and
the `Content-Type` that carries the boundary. Give the boundary when the receiver
already knows it; leave it out and the library generates one it has proven absent
from every part.

```moonbit
let form = @moonmime.Form::new(
  fields=[{ name: "title", value: "a report" }],
  files=[
    {
      name: "file",
      filename: "résumé.pdf",
      content_type: "application/pdf",
      content: b"%PDF",
      headers: [],
    },
  ],
)
let written = form.encode()
assert_eq(written.content_type(), "multipart/form-data; boundary=----moonmime")
let back = @moonmime.formdata(written.body[:], written.boundary)
assert_eq(back.field("title"), Some("a report"))
assert_eq(back.file("file").unwrap().filename, "résumé.pdf")
```

`Multipart::new` frames parts that are not a form — `multipart/mixed`, the shape an
email with an attachment has:

```moonbit
let mixed = @moonmime.Multipart::new([
  { headers: [("content-type", "text/plain")], body: b"hola" },
])
assert_eq(mixed.content_type(), "multipart/mixed; boundary=----moonmime")
assert_eq(@moonmime.multipart(mixed.body[:], mixed.boundary)[0].body, b"hola")
```

## Read a body as it arrives

`PartsReader` answers with a part's header fields first and its body in chunks after
that, so a caller can drop a part it does not want without its octets being read. A
`Source` hands over the octets; `Chunks` is the one for a body already in hand.

```moonbit
let source : &@moonmime.Source = @moonmime.Chunks::new(
  b"--b\r\nContent-Disposition: form-data; name=\"title\"\r\n\r\nhello\r\n--b--\r\n",
)
let reader = @moonmime.PartsReader::new(source, "b")
let head = reader.next_part().unwrap()
assert_eq(head.disposition().unwrap().param("name"), Some("title"))
assert_eq(reader.read().unwrap(), b"hello")
assert_eq(reader.next_part() is None, true)
```

`PartsReader::over(body, boundary)` reads a body already in hand the same way. The
`Limits` hold during the read: a part over its size is refused where it is crossed.

## Write a body a part at a time

`MultipartWriter` hands the delimiter, the header block and the body octets to a
`Sink` as it gets them, so nothing larger than a chunk is ever held. `Gathered` is a
sink that keeps the octets.

```moonbit
let sink = @moonmime.Gathered::new()
let writer = @moonmime.MultipartWriter::new(sink, boundary="b")
writer.begin_part([("content-type", "text/plain")])
writer.body(b"hola")
writer.close()
assert_eq(writer.content_type(), "multipart/mixed; boundary=b")
assert_eq(@moonmime.multipart(sink.bytes()[:], "b")[0].body, b"hola")
```

`Form::parts()` gives the parts a form frames to, in the order a body carries them.

## A related body

`multipart/related` says which part is the root. `Related` writes the header with its
`type`, `start` and `start-info`, and `root()` reads `start` back into the part it
names — the first part when the header names none, `None` when it names one the body
does not hold.

```moonbit
let related = @moonmime.Related::new(
  [{ headers: [("content-id", "<root>"), ("content-type", "text/html")], body: b"hi" }],
  boundary="b",
  type_="text/html",
  start="<root>",
)
assert_eq(related.root().unwrap().content_id(), Some("root"))
let read = @moonmime.related(related.content_type(), related.body())
assert_eq(read.parts.length(), 1)
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
- A boundary you pass has to be RFC 2046's bchars, no more than 70 of them, and
  absent from every part; anything else raises `Boundary` and writes nothing.
- The header value is `content_type()` and the body is `body`: the boundary stands
  in both, and a receiver needs both to split the octets.
- A form's fields go out before its files, in the order the `Form` holds them. A
  `Form` keeps the two apart, so a body whose parts interleaved them will not come
  back in the order it arrived.
- A file name that leaves ASCII is written as `filename*` (RFC 5987); a parsed
  part's `Content-Disposition` is rebuilt from the `Upload`, so it goes back out
  with one disposition rather than the parsed one and a second one.
- A part a reader abandons is discarded before the next head, and still counts
  against the bound: `next_part` without reading the body is not a way around it.
- `MultipartWriter` raises `Error`, because a sink's own failures come through the
  same call. Catch it and match `@moonmime.Boundary(got~)` for the one case the
  library decides.
- The boundary a streaming writer generates is a fixed stem, watched for in the
  octets as they go by; a collision raises, and the octets already in the sink cannot
  be taken back. Pass a boundary when that matters, or write the body in one call.
- `Related::root()` is `None` when `start` names no part in the body — a header and a
  body that disagree, rather than something to guess at.
- Quoted-printable and encoded words are in `moonbitstack/moonmime/qp` and the
  `encode_words` / `decode_words` of the root package.
