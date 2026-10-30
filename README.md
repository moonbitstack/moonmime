<h1 align="center">moonmime</h1>

<p align="center"><strong>The MIME family for MoonBit.</strong><br>
Media types and their parameters, the filename-to-type registry, <code>Content-Disposition</code>,<br>
multipart bodies, and <code>multipart/form-data</code>. Bytes in, data out.</p>

<p align="center">
<a href="https://moonbitstack.github.io/moonmime/">Home</a> &nbsp;·&nbsp;
<a href="https://moonbitstack.github.io/moonmime/guide.html">Guide</a> &nbsp;·&nbsp;
<a href="https://moonbitstack.github.io/moonmime/api.html">API</a> &nbsp;·&nbsp;
<a href="https://mooncakes.io/docs/#/moonbitstack/moonmime">mooncakes</a>
</p>

---

`moonmime` reads and writes the parts of a message that describe what the content is:
the `Content-Type` header and its parameters, the `Content-Disposition` that names a
file, and the multipart body that carries a request or an email. It holds no sockets,
opens no files, and keeps no global state — you hand it bytes and a header, it hands
back data.

## What it does

- **Media types.** Parse a `Content-Type` into an essence and ordered parameters, and
  write it back with correct quoting (RFC 2045 §5.1, RFC 2046 §4.2).
- **The registry.** Map a filename to the media type its extension implies, and a
  media type to the extension people actually use.
- **Content-Disposition.** Build and parse the header that names a download, with
  `filename*` (RFC 5987) for names that leave ASCII.
- **Multipart.** Split any multipart body into parts (RFC 2046 §5.1) — the shape an
  email and a form upload share.
- **Form data.** Read `multipart/form-data` (RFC 7578) into text fields and file
  uploads, and build the same type from either.
- **Encoded words.** Write a header value as RFC 2047 encoded words, `B` or `Q`,
  split so no word passes 75 characters, and read any mix of words and plain text back.
- **Quoted-printable.** `moonmime/qp` encodes and decodes a body (RFC 2045 §6.7):
  soft breaks at 76 columns, `=XY` escapes, trailing whitespace protected.
- **Charsets.** UTF-8, US-ASCII and ISO-8859-1 come with the library; any other set
  is a `Charset` you pass in, so nothing is registered globally.

## Install

```sh
moon add moonbitstack/moonmime
```

```moonbit
import {
  "moonbitstack/moonmime",
}
```

## Use it

### Read a media type

```moonbit
let mt = @moonmime.media_type("Text/HTML; charset=UTF-8")
println(mt.essence)                         // text/html
println(mt.type_())                         // text
println(mt.subtype())                       // html
println(mt.param("charset").unwrap_or(""))  // UTF-8
println(mt.to_string())                     // text/html; charset=UTF-8
```

A value it cannot make sense of is dropped, not guessed at: `media_type("")` has an
empty essence and no parameters.

### Name a download

```moonbit
println(@moonmime.content_disposition("menu.pdf"))
// attachment; filename="menu.pdf"

println(@moonmime.content_disposition("receta \"de la abuela\".pdf"))
// attachment; filename*=utf-8''receta%20%22de%20la%20abuela%22.pdf
```

On the way in, `Disposition::parse` reads a header back, and `filename` prefers
`filename*` over `filename`:

```moonbit
let d = @moonmime.Disposition::parse(
  "attachment; filename=\"fallback.txt\"; filename*=utf-8''r%C3%A9sum%C3%A9.txt",
)
println(d.filename().unwrap_or(""))  // résumé.txt
```

### Guess from a filename

```moonbit
println(@moonmime.guess_type("photo.jpg"))                    // image/jpeg
println(@moonmime.guess_type("archive.tar.gz"))               // application/gzip
println(@moonmime.guess_extension("image/jpeg").unwrap_or(""))  // .jpg
```

Anything the registry has not heard of is `application/octet-stream`, the value
`fallback` holds.

### Split a body, then read it as a form

```moonbit
// `body` is the raw bytes; `boundary` is the delimiter without its leading dashes.
let parts = @moonmime.multipart(body, boundary)
for part in parts {
  println(part.header("content-type").unwrap_or(""))
}

let form = @moonmime.formdata(body, boundary)
let title = form.field("title")            // String?
for tag in form.values("tags") {           // every value under one name
  println(tag)
}
let upload = form.file("photo")            // Upload?
```

A part becomes a file when its `Content-Disposition` carries a `filename`, and a text
field when it does not — the only thing distinguishing them on the wire.

### Write a header that leaves ASCII, and a body that must stay 7-bit

```moonbit
let subject = @moonmime.encode_words("Grüße aus München")  // =?utf-8?B?...?=
let back = @moonmime.decode_words(subject)                 // Grüße aus München
let body = @qp.encode(b"caf\xc3\xa9 = coffee")             // caf=C3=A9 =3D coffee
let text = @qp.decode(body)
```

A charset the library does not ship is a `Charset` handed to the call that needs it,
keyed by its lower-case name; it is consulted before the three that ship:

```moonbit
let charsets : Map[String, &@moonmime.Charset] = { "windows-1252": cp1252 }
let name = @moonmime.decode_words(header, charsets~)
```

## Interface

| Item | What it does |
| --- | --- |
| `media_type(s)` | Parse a `Content-Type` header into a `MediaType`. |
| `MediaType` | `type_`, `subtype`, `param(name)`, `to_string`. |
| `guess_type(filename)` | The media type a filename's extension implies. |
| `guess_extension(type)` | The extension people use for a media type. |
| `fallback` | `application/octet-stream`. |
| `content_disposition(name, inline?)` | Build a `Content-Disposition` header. |
| `Disposition` | `parse`, `param(name)`, `filename()`. |
| `multipart(body, boundary, limits?, strict?)` | Split a multipart body into `Part`s. |
| `Part` | `header(name)`, `content_type()`, `disposition()`. |
| `formdata(body, boundary, limits?, strict?)` | Read `multipart/form-data` into a `Form`. |
| `Form` | `field`, `values`, `file`, `entries`, `uploads`, `is_empty`, `new`. |
| `Upload` | `size()`, `header(name)`. |
| `Limits` / `limits` | Bounds on part count and part size. |
| `encode_word(text, charset?, encoding?, charsets?)` | One RFC 2047 encoded word. |
| `encode_words(text, ...)` | A header value as encoded words, split to fit; ASCII stays as it is. |
| `decode_words(value, charsets?)` | Read encoded words back, dropping the folding between them. |
| `WordEncoding` | `Base64` or `QuotedPrintable`, the `B` and `Q` of RFC 2047. |
| `Charset` | The trait a further charset implements: `decode`, `encode`. |
| `decode_charset(name~, data~, charsets?)` / `encode_charset(...)` | Bytes to text in a named charset, and back. |
| `Refused` | Why a body was not read: `Parts`, `Part`, `Malformed`, `NotAForm`, `Charset`. |
| `@qp.encode(bytes)` / `@qp.decode(bytes, strict?)` | Quoted-printable, from `moonbitstack/moonmime/qp`. |

## Bounds

`multipart` and `formdata` take a `Limits` — a thousand parts of a megabyte each by
default. A body over its bound is refused whole, not truncated. A body that stops
making sense returns what it read so far; `strict` turns that into an error.

```moonbit
let small = @moonmime.Limits::new(parts=8, part_size=64 * 1024)
let form = @moonmime.formdata(body, boundary, limits=small)
```

## Examples

`src/examples/` holds small programs that run:

- `src/examples/lookup` — filenames and media types, both directions.
- `src/examples/form` — read a `multipart/form-data` upload, then the raw parts.
- `src/examples/tour` — every call once, end to end.
- `src/examples/browser` — the same library compiled to JavaScript for the live demos.

```sh
moon run src/examples/lookup
moon run src/examples/form
moon run src/examples/tour
```

## Licence

Apache-2.0. See [LICENSE](LICENSE).
