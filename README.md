# moonmime

The MIME family for MoonBit: media types and their parameters, the extension-to-type
registry, `Content-Disposition`, multipart bodies, and `multipart/form-data`. Bytes in,
data out — no sockets, no files, no global state.

## What is here

- **`media_type` / `MediaType`** — parse a `Content-Type` into its essence and
  parameters (RFC 2045 §5.1, RFC 2046 §4.2), and write it back.
- **`guess_type` / `guess_extension`** — the extension-to-type table Python's
  `mimetypes` ships: which type a filename implies, which extension a type usually
  takes.
- **`content_disposition` / `Disposition`** — build and parse `Content-Disposition`
  (RFC 6266), with `filename` and `filename*` (RFC 5987).
- **`multipart`** — split any multipart body into parts (RFC 2046 §5.1); the shape a
  form upload and an email share.
- **`formdata` / `Form`** — read `multipart/form-data` (RFC 7578) into text fields and
  file uploads, bounded by `Limits`. `Form::new` builds one from fields and files, so a
  decoder of the other form encoding hands back the same type.

## Bounds

`multipart` and `formdata` take a `Limits` — a thousand parts of a megabyte each by
default, what Starlette and python-multipart default to. A body over its bound is
refused whole, not truncated. A body that stops making sense returns what it read so
far; `strict` turns that into an error.

## Not here

- Sockets, files, streams: parts are held whole; spilling a part to disk is the
  caller's loop around this package.
- `application/x-www-form-urlencoded`: that is the WHATWG URL Standard's, and lives in
  [moonurl](https://github.com/moonbitstack/moonurl) as `Query`. Picking one of the two
  form decoders by `Content-Type` is moonhttp's `form`.
- Transfer encodings: a part's `Content-Transfer-Encoding` header is surfaced on the
  part; decoding it is the caller's call.

## Example

`examples/tour/main.mbt` runs the calls end to end — `moon run examples/tour`:
guessing `tacos-al-pastor.png`, naming `receta "de la abuela".pdf` the RFC 5987 way,
and pulling `chiles en nogada` out of a form.

## Licence

Apache-2.0. See [LICENSE](LICENSE).
