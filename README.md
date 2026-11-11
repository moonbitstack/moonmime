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
  write it back with correct quoting (RFC 2045 §5.1, RFC 2046 §4.2). Strict reading
  follows the MIME Sniffing standard for the places where a wrong guess is worse than
  a refusal.
- **The registry.** Map a filename to the media type its extension implies, and a
  media type to the extension people actually use.
- **Content-Disposition.** Build and parse the header that names a download, with
  `filename*` (RFC 5987) for names that leave ASCII.
- **Multipart.** Split any multipart body into parts (RFC 2046 §5.1) — the shape an
  email and a form upload share.
- **Streaming.** Read a part's header fields before its body has arrived and take
  the body as it comes; write a body a part at a time into a sink. The bounds hold
  while reading, not after.
- **Related.** `multipart/related` (RFC 2387) with its `type`, `start` and
  `start-info`: which part is the root, and what the root is to be read as.
- **Form data.** Read `multipart/form-data` (RFC 7578) into text fields and file
  uploads.
- **Writing.** Frame parts as `multipart/mixed`, or a `Form` as
  `multipart/form-data`, with a boundary proven absent from the content and
  `filename*` (RFC 5987) for a file name that leaves ASCII.
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

When a header decides what a file is, ask the strict reader instead. `MediaType::parse`
follows the MIME Sniffing standard: a `type/subtype` of tokens, `;name=value`
parameters in order, and `None` for anything else — including a value that is a list,
a lone type, or a parameter name with a space in it.

```moonbit
let mt = @moonmime.MediaType::parse("Text/HTML; charset=\"utf-8\"").unwrap()
println(mt.essence)                          // text/html
println(mt.param("charset").unwrap_or(""))   // utf-8

let listed = @moonmime.MediaType::parse("text/html, text/plain")
println(listed is None)                      // true
```

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
let boundary = "----edge"
let body = b"------edge\r\nContent-Disposition: form-data; name=\"recipe\"\r\n\r\nchiles en nogada\r\n------edge--\r\n"
let parts = @moonmime.multipart(body[:], boundary)
assert_eq(parts.length(), 1)
assert_eq(parts[0].header("content-disposition").unwrap_or(""), "form-data; name=\"recipe\"")

let form = @moonmime.formdata(body[:], boundary)
assert_eq(form.field("recipe"), Some("chiles en nogada"))
assert_eq(form.uploads().length(), 0)
```

A part becomes a file when its `Content-Disposition` carries a `filename`, and a text
field when it does not — the only thing distinguishing them on the wire.

### Write one back

`Form::encode` frames a form the way a browser sends one: fields first, then files.
A boundary you do not give is generated and proven absent from the parts, so the
same form always comes out as the same octets.

```moonbit
let fields : Array[@moonmime.Field] = [
  { name: "recipe", value: "chiles en nogada" },
  { name: "mood", value: "happy" },
]
let written = @moonmime.Form::new(fields~).encode(boundary="----edge")
assert_eq(written.content_type(), "multipart/form-data; boundary=----edge")
assert_eq(
  @moonmime.formdata(written.body[:], written.boundary).field("mood"),
  Some("happy"),
)
```

A file name that leaves ASCII goes out as `filename*`; a boundary you pass has to be
RFC 2046's bchars and cannot already stand inside a part.

```moonbit
let named = @moonmime.Form::new(
  files=[
    {
      name: "doc",
      filename: "résumé.pdf",
      content_type: "application/pdf",
      content: b"%PDF",
      headers: [],
    },
  ],
).encode(boundary="----edge")
let part = @moonmime.multipart(named.body[:], named.boundary)[0]
assert_eq(
  part.header("content-disposition"),
  Some("form-data; name=\"doc\"; filename*=utf-8''r%C3%A9sum%C3%A9.pdf"),
)
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

### Read a body as it arrives

`multipart` hands back a body whole. When the octets come from a socket or a file,
`PartsReader` takes them as they arrive: the header fields of a part first, then its
body in chunks. A caller that decides it does not want a part stops reading it, and
what stands behind it is never pulled.

```moonbit
let raw = b"------edge\r\nContent-Disposition: form-data; name=\"recipe\"\r\n\r\nchiles en nogada\r\n------edge--\r\n"
let reader = @moonmime.PartsReader::new(@moonmime.Chunks::new(raw[:]), "----edge")
let head = reader.next_part().unwrap()
assert_eq(head.header("content-disposition").unwrap_or(""), "form-data; name=\"recipe\"")
assert_eq(head.disposition().unwrap().param("name"), Some("recipe"))
assert_eq(reader.read().unwrap(), b"chiles en nogada")
assert_eq(reader.next_part() is None, true)
```

A source is anything that hands over octets a piece at a time — the `Source` trait has
one method, `next`, which answers `None` once the body has ended. `Chunks` is the
adapter for a body already in hand. `PartsReader::over(body, boundary)` is the same
reader without the adapter.

Writing goes the other way: `MultipartWriter` hands the delimiter, the header block
and the body octets to a `Sink` as it is given them, so a body larger than memory is
framed without ever standing in it. `Gathered` is a sink that keeps the octets, for
a caller that wants them after all.

```moonbit
let sink = @moonmime.Gathered::new()
let writer = @moonmime.MultipartWriter::new(
  sink,
  boundary="----edge",
  kind=@moonmime.MultipartKind::FormData,
)
writer.begin_part([("content-disposition", "form-data; name=\"recipe\"")])
writer.body(b"chiles en nogada")
writer.close()
assert_eq(writer.content_type(), "multipart/form-data; boundary=----edge")
assert_eq(
  @moonmime.formdata(sink.bytes()[:], "----edge").field("recipe"),
  Some("chiles en nogada"),
)
```

A form is a list of parts, so `Form::parts()` is what a caller streams: same headers,
same order, one part at a time. The octets are the ones `Form::encode` writes for the
same boundary, and a test in this repository holds the two to be equal byte for byte.

### A related body

`multipart/related` says the parts belong together and names one of them as the root.
The framing is the one every multipart subtype shares; `Related` adds the three
parameters RFC 2387 defines and reads `start` back into the part it names.

```moonbit
let related = @moonmime.Related::new(
  [
    {
      headers: [("content-id", "<root>"), ("content-type", "text/html")],
      body: b"<img src=\"cid:logo\">",
    },
    {
      headers: [("content-id", "<logo>"), ("content-type", "image/png")],
      body: b"\x89PNG",
    },
  ],
  boundary="----rel",
  type_="text/html",
  start="<root>",
)
assert_eq(
  related.content_type(),
  "multipart/related; boundary=----rel; type=\"text/html\"; start=\"<root>\"",
)
let read = @moonmime.related(related.content_type(), related.body())
assert_eq(read.root().unwrap().content_id(), Some("root"))
assert_eq(read.root().unwrap().body, b"<img src=\"cid:logo\">")
```

`start` matches a part's `Content-ID` with or without its angle brackets, and a header
that names nothing gives `root() == None` rather than a guess. With no `start` at all
the first part is the root, which is the RFC's default. The header is not related at
all, or names no boundary, and `related` refuses it with `NotRelated` or `Boundary`.

### Write a header that leaves ASCII, and a body that must stay 7-bit

```moonbit
let subject = @moonmime.encode_words("Grüße aus München")
assert_eq(@moonmime.decode_words(subject), "Grüße aus München")

let qp_bytes = @qp.encode(b"caf\xc3\xa9 = coffee")
assert_eq(@qp.decode(qp_bytes), b"caf\xc3\xa9 = coffee")
```

The three charsets that ship — UTF-8, US-ASCII and ISO-8859-1 — answer to their
names directly; anything else is a `Charset` handed to the call that needs it, keyed
by its lower-case name and consulted before the shipped sets:

```moonbit
assert_eq(@moonmime.encode_charset(name="iso-8859-1", text="é"), b"\xe9")
assert_eq(@moonmime.decode_charset(name="iso-8859-1", data=b"\xe9"), "é")
```

## Interface

| Item | What it does |
| --- | --- |
| `media_type(s)` | Parse a `Content-Type` header into a `MediaType`, keeping what it can. |
| `MediaType::parse(s)` | Read a value strictly, as the MIME Sniffing standard does; `None` for anything else. |
| `MediaType` | `type_`, `subtype`, `param(name)`, `to_string`. |
| `guess_type(filename)` | The media type a filename's extension implies. |
| `guess_extension(type)` | The extension people use for a media type. |
| `fallback` | `application/octet-stream`. |
| `content_disposition(name, inline?)` | Build a `Content-Disposition` header. |
| `Disposition` | `parse`, `param(name)`, `filename()`. |
| `multipart(body, boundary, limits?, strict?)` | Split a multipart body into `Part`s. |
| `PartsReader::new(source, boundary, limits?, strict?)` | Read parts as they arrive: `next_part()` for a head, `read()` for the body in chunks. |
| `PartsReader::over(body, boundary, limits?, strict?)` | The same reader over a body already in hand. |
| `Source` / `Chunks` | The trait a byte source implements (`next`), and the adapter for a body held whole. |
| `PartHead` | `header(name)`, `content_type()`, `disposition()`, `content_id()`. |
| `Part` | `header(name)`, `content_type()`, `disposition()`, `content_id()`. |
| `formdata(body, boundary, limits?, strict?)` | Read `multipart/form-data` into a `Form`. |
| `Form::encode(boundary?)` | Write the form as a `multipart/form-data` body. |
| `Multipart::new(parts, boundary?, kind?)` | Frame parts as a multipart body, `mixed` unless told otherwise. |
| `Multipart` | `content_type()`, and the `kind`, `boundary` and `body` it was built with. |
| `MultipartKind` | `FormData` or `Mixed`; `code()` is the subtype as written. |
| `MultipartWriter::new(sink, boundary?, kind?)` | Frame a body a part at a time: `begin_part(headers)`, `body(bytes)`, `close()`, `content_type()`. |
| `Sink` / `Gathered` | The trait a sink implements (`write(chunk)`) and a sink that keeps the octets. |
| `Related::new(parts, boundary?, type_?, start?, start_info?)` | Frame a `multipart/related` body (RFC 2387). |
| `related(content_type, body, limits?, strict?)` | Read one: its parameters and its parts. |
| `Related` | `body()`, `content_type()`, `root()`, and the `type_`, `start`, `start_info`, `boundary` and `parts` it holds. |
| `Form::parts()` | The parts a form frames to, for a caller that writes them itself. |
| `Form` | `field`, `values`, `file`, `entries`, `uploads`, `is_empty`, `new`. |
| `Upload` | `size()`, `header(name)`. |
| `Limits` / `limits` | Bounds on part count and part size. |
| `encode_word(text, charset?, encoding?, charsets?)` | One RFC 2047 encoded word. |
| `encode_words(text, ...)` | A header value as encoded words, split to fit; ASCII stays as it is. |
| `decode_words(value, charsets?)` | Read encoded words back, dropping the folding between them. |
| `WordEncoding` | `Base64` or `QuotedPrintable`, the `B` and `Q` of RFC 2047. |
| `Charset` | The trait a further charset implements: `decode`, `encode`. |
| `decode_charset(name~, data~, charsets?)` / `encode_charset(...)` | Bytes to text in a named charset, and back. |
| `Refused` | Why a body was not read, or not written: `Parts`, `Part`, `Malformed`, `NotAForm`, `NotRelated`, `Charset`, `Boundary`. |
| `@qp.encode(bytes)` / `@qp.decode(bytes, strict?)` | Quoted-printable, from `moonbitstack/moonmime/qp`. |

## Bounds

`multipart` and `formdata` take a `Limits` — a thousand parts of a megabyte each by
default. A body over its bound is refused whole, not truncated. A body that stops
making sense returns what it read so far; `strict` turns that into an error.

`PartsReader` holds the same bound while it reads: a part that passes its size is
refused where it is crossed, and the octets behind it are never pulled. What a reader
has already handed over cannot be taken back, so a part the caller abandons is
discarded — and still counted against the bound — before the next head.

`multipart` is `PartsReader` walked to its end, so the two cannot drift apart. The
tests read the same bodies at one-octet, four-octet and nine-octet chunks — a folded
header, a part with no header field, a delimiter's stem inside a body, an empty part,
a body with no parts — and require every part to be the one the whole-body read
gives. The interop check then writes all seventeen cases a second time through the
streaming writer and compares the octets.

```moonbit
let small = @moonmime.Limits::new(parts=8, part_size=64 * 1024)
assert_eq(@moonmime.formdata(body[:], boundary, limits=small).field("recipe"), Some("chiles en nogada"))
```

## Examples

`src/examples/` holds small programs that run:

- `src/examples/lookup` — filenames and media types, both directions.
- `src/examples/form` — read a `multipart/form-data` upload, then write it back.
- `src/examples/stream` — read a body a chunk at a time, write one a part at a time.
- `src/examples/tour` — every call once, end to end.
- `src/examples/browser` — the same library compiled to JavaScript for the live demos.

```sh
moon run src/examples/lookup
moon run src/examples/form
moon run src/examples/stream
moon run src/examples/tour
```

## Conformance

Media type parsing is checked against the Web Platform Tests suite for the
[MIME Sniffing standard](https://mimesniff.spec.whatwg.org/). The suite's data files are
kept in `scripts/wpt/mimesniff/` at a pinned commit and turned into MoonBit cases by
`scripts/gen_wpt_vectors.py`. `MediaType::parse` is what those cases run against;
`media_type` is the forgiving reader and is not the subject of the suite.

| Data file | Cases | Passing |
| --- | --- | --- |
| `mimesniff/mime-types/resources/mime-types.json` | 74 | 74 |
| `mimesniff/mime-types/resources/generated-mime-types.json` | 881 | 881 |

Pinned at commit `2ed27cab3330f835ebdae3d4cd1ad14b729fdd85` of
`web-platform-tests/wpt`, dated 2026-11-06.

The rest of that directory is out of scope here, and nothing in it is claimed:

- `mimesniff/sniffing/*` and `mimesniff/media/*` ask what a browser does with a
  response — whether an `<img>`, an `<iframe>`, or a navigation keeps the type it was
  handed. Answering them needs an HTML parser and a network stack. This library decides
  the type of a value it is given; it does not sniff content.
- `mimesniff/mime-types/charset-parameter.window.js` checks which encoding a frame
  derives from a `charset` parameter, which is document decoding rather than the header
  itself.
- `resources/mime-groups.json` lists the groups a type belongs to for `Accept`
  computation; this library has no group API.
- `resources/mime-types-minimized.json` covers the navigation algorithm's *minimized*
  MIME type, which also needs a browsing context.

<!-- mime-diff:begin -->
### The extension table

`guess_type` and `guess_extension` are decided by a table of the common
extensions, the part the implementations most often disagree on. It was
differed against Python's `mimetypes` and Go's `mime`; every extension the
references know about is replayed by a test, and where the references
disagree the table takes a side: IANA where it registers one, the more
specific name where it does not. The task also named `.ts` and `.js`, so
they are decided here too — one line each:

| Extension | moonmime | Python `mimetypes` | Go `mime` | Why |
| --- | --- | --- | --- | --- |
| `.3gp` | video/3gpp | audio/3gpp | — | IANA registers video/3gpp for the 3GPP container; Python's audio/3gpp keeps only the audio track. |
| `.heic` | image/heic | image/heic | — | IANA registers image/heic for .heic, as Python does; the table's old image/heif borrowed the .heif sibling's subtype, so it is corrected to the IANA and Python side. |
| `.srt` | application/x-subrip | text/plain | — | neither side is IANA-registered; keeps the specific x- name over Python's generic text/plain. |
| `.wav` | audio/wav | audio/x-wav | — | IANA registered audio/wav in 2018, retiring audio/x-wav; takes the IANA side over Python's x- form. |
| `.xml` | application/xml | text/xml | text/xml | IANA registers application/xml (RFC 7303); the text/xml alias is retired, which Go still ships. |
| `.sh` | text/x-shellscript | application/x-sh | — | neither side is IANA-registered; keeps the semantic x- name over Python's application/x-sh. |
| `.ts` | video/mp2t | — | — | IANA registers video/mp2t for the MPEG-2 transport stream, the common meaning of .ts; neither reference ships it. |
| `.js` | text/javascript | text/javascript | text/javascript | all three agree and IANA registers text/javascript; Go's charset=utf-8 is a default parameter, not a different essence. |

The rest of the union the library has no entry for — it answers `application/octet-stream` for them, which is what `guess_type` promises
for a name it has not heard.
<!-- mime-diff:end -->

### Bidirectional interop

Multipart framing is checked against two other implementations, in both
directions. Each one writes the body for every case, and every implementation —
the writer among them — reads that body back; what it read is compared with what
the case says went in. `scripts/check_multipart_interop.py` drives the three, and
`scripts/interop/cases.json` is the corpus. The library's side of the exchange is
`integration/interop`, a program outside the package that is built and run for the
check only.

| Partner | Cases | Bodies it wrote, read by the other two |
| --- | --- | --- |
| this library | 17 | 17 of 17 |
| Python 3.13, `email` | 17 | 17 of 17 |
| Go 1.25, `mime/multipart` | 17 | 17 of 17 |

The same run also writes every case a second time through the streaming writer and
compares the two bodies byte for byte: 17 of 17 are the same octets, so "a part at a
time" is not a second framing.

The corpus holds fields sharing a name, a value with CRLF in it, a binary file, a
file name with an accent and a quote in it, a part with no `Content-Type`, a
boundary with a space, a boundary the writer chooses, `multipart/mixed` bodies,
`multipart/related` bodies with `type`, `start` and `start-info`, a root that is not
the first part, a header whose `start` names a part the body does not hold, and a
body with no parts at all.

Two behaviours the corpus pins because they are what a reader has to survive:

- **Folded headers.** Python's generator folds a long `Content-Disposition` across
  lines, so a part's header block arrives folded. Reading unfolds it (RFC 5322
  §2.2.3): the break is dropped and the whitespace that opens the continuation
  stands for it.
- **A body with no parts.** This library writes one closing delimiter. Python's
  generator writes an opening delimiter, a blank line and then the closing one,
  which every reader in reach takes for a single part with no header field and no
  content. The case says so, and the check requires the disagreement to still be
  there rather than pass over it.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
