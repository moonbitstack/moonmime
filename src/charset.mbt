// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// How the bytes of a body turn into the text they carry, and back. Three come
/// with the library; everything else arrives through this trait, so a codebase
/// that needs windows-1252 does not need a fork of this one.
pub(open) trait Charset {
  fn decode(Self, BytesView) -> String raise Refused
  fn encode(Self, StringView) -> Bytes raise Refused
}

///|
priv struct Utf8 {}

///|
impl Charset for Utf8 with fn decode(_self : Utf8, data : BytesView) -> String raise Refused {
  @utf8.decode_lossy(data)
}

///|
impl Charset for Utf8 with fn encode(_self : Utf8, text : StringView) -> Bytes raise Refused {
  @utf8.encode(text)
}

///|
priv struct Ascii {}

///|
/// US-ASCII in name, Latin-1 in tolerance: mail that declares ASCII and carries
/// a stray high octet is too common to refuse, so it is read as ISO-8859-1 and
/// never the other way around — encoding refuses what cannot be written.
impl Charset for Ascii with fn decode(_self : Ascii, data : BytesView) -> String raise Refused {
  latin1_text(data)
}

///|
impl Charset for Ascii with fn encode(_self : Ascii, text : StringView) -> Bytes raise Refused {
  let out = Buffer()
  for c in text {
    let n = code(c)
    if n > 127 {
      raise Refused::Charset(name="us-ascii")
    }
    out.write_byte(n.to_byte())
  }
  out.to_bytes()
}

///|
priv struct Latin1 {}

///|
impl Charset for Latin1 with fn decode(_self : Latin1, data : BytesView) -> String raise Refused {
  latin1_text(data)
}

///|
impl Charset for Latin1 with fn encode(_self : Latin1, text : StringView) -> Bytes raise Refused {
  let out = Buffer()
  for c in text {
    let n = code(c)
    if n > 255 {
      raise Refused::Charset(name="iso-8859-1")
    }
    out.write_byte(n.to_byte())
  }
  out.to_bytes()
}

///|
/// One octet, one character: the identity mapping the ISO-8859 family shares,
/// and what a message is read as when the declared set cannot represent what it
/// carries. Undecodable encoder keeps going, so a partially known body survives.
fn latin1_text(data : BytesView) -> String {
  let out = StringBuilder()
  for b in data {
    out.write_char(b.to_char())
  }
  out.to_string()
}

///|
/// The sets that come with the library, by every name they answer to.
fn builtin(name : String) -> &Charset? {
  match name {
    "utf-8" | "utf8" => Some(Utf8::{ })
    "us-ascii" | "ascii" => Some(Ascii::{ })
    "iso-8859-1" | "latin1" | "l1" => Some(Latin1::{ })
    _ => None
  }
}

///|
/// The codec for `name`: the caller's own first, so a name can be aliased or
/// a shipped set replaced, then the three that ship. `charsets` is keyed by
/// lower-case names.
fn lookup(
  name : StringView,
  charsets : Map[String, &Charset]?,
) -> &Charset raise Refused {
  let known = lower(name)
  if charsets is Some(map) && map.get(known) is Some(codec) {
    return codec
  }
  builtin(known).unwrap_or_error(Refused::Charset(name=known))
}

///|
/// Read `data` as `name` says it was written. Unmapping octets become U+FFFD so
/// that one bad byte costs one character and not the whole part.
///
/// ```mbt check
/// test {
///   let text = @moonmime.decode_charset(name="iso-8859-1", data=b"\xe9") catch {
///     _ => ""
///   }
///   inspect(text, content="é")
/// }
/// ```
pub fn decode_charset(
  name~ : StringView,
  data~ : BytesView,
  charsets? : Map[String, &Charset],
) -> String raise Refused {
  lookup(name, charsets).decode(data)
}

///|
/// Write `text` in `name`, refusing a character the set has no room for.
///
/// ```mbt check
/// test {
///   let bytes = @moonmime.encode_charset(name="iso-8859-1", text="é") catch {
///     _ => b""
///   }
///   inspect(bytes == b"\xe9", content="true")
/// }
/// ```
pub fn encode_charset(
  name~ : StringView,
  text~ : StringView,
  charsets? : Map[String, &Charset],
) -> Bytes raise Refused {
  lookup(name, charsets).encode(text)
}

///|
/// A tiny codec used only to prove a caller's own charset is dispatched to:
/// Caesar-1 over ASCII, so `a`→`b` and `b`→`c`.
priv struct Shift1 {}

///|
impl Charset for Shift1 with fn decode(_self : Shift1, data : BytesView) -> String raise Refused {
  let out = Buffer()
  for b in data {
    out.write_byte((b.to_int() + 1).to_byte())
  }
  @utf8.decode_lossy(out.to_bytes()[:])
}

///|
impl Charset for Shift1 with fn encode(_self : Shift1, text : StringView) -> Bytes raise Refused {
  let out = Buffer()
  for c in text {
    out.write_byte((c.to_int() - 1).to_byte())
  }
  out.to_bytes()
}

///|
/// A caller's codec answers by its lower-cased name, before the shipped sets.
test {
  let charsets : Map[String, &Charset] = { "x-shift1": Shift1::{ } }
  inspect(
    decode_charset(name="X-Shift1", data=@utf8.encode("bcde")[:], charsets~),
    content="cdef",
  )
  let latin : Map[String, &Charset] = { "iso-8859-1": Shift1::{ } }
  inspect(
    decode_charset(name="iso-8859-1", data=b"bcde", charsets=latin),
    content="cdef",
  )
}

///|
/// Encoding is allowed to refuse what cannot be written, while decoding is not:
/// US-ASCII has no room for `é`, so the encoder reports `Charset`.
test {
  let raised = try {
    let _ = encode_charset(name="us-ascii", text="é")
    false
  } catch {
    _ => true
  }
  inspect(raised, content="true")
}
