// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The two encodings RFC 2047 §4 allows inside an encoded word, named for the
/// letter that announces them in the header itself.
pub(all) enum WordEncoding {
  Base64
  QuotedPrintable
} derive(Eq)

///|
pub extend WordEncoding with Eq::{not_equal, equal}

///|
fn WordEncoding::letter(self : WordEncoding) -> Char {
  match self {
    WordEncoding::Base64 => 'B'
    WordEncoding::QuotedPrintable => 'Q'
  }
}

///|
/// The safe set of the Q encoding: alphanumerics and the five punctuation marks
/// RFC 2047 §4.2 kept, since they stand for nothing inside a header. Space
/// becomes `_`; everything else becomes `=XY`.
fn q_word_encode(data : BytesView) -> String {
  let out = StringBuilder()
  for b in data {
    let c = b.to_char()
    if is_alpha(c) || is_digit(c) {
      out.write_char(c)
    } else if c == ' ' {
      out.write_char('_')
    } else if c == '-' || c == '!' || c == '*' || c == '+' || c == '/' {
      out.write_char(c)
    } else {
      let n = byte_code(b)
      out.write_char('=')
      out.write_char(hex_digit(n / 16))
      out.write_char(hex_digit(n % 16))
    }
  }
  out.to_string()
}

///|
/// One encoded word, however long it comes out. Callers answerable to the 75
/// character limit RFC 2047 puts on a word use `encode_words` instead.
fn word_body(data : BytesView, encoding : WordEncoding) -> String {
  match encoding {
    WordEncoding::Base64 => @base64.encode(data)
    WordEncoding::QuotedPrintable => q_word_encode(data)
  }
}

///|
fn wrap_word(
  data : BytesView,
  charset : StringView,
  encoding : WordEncoding,
) -> String {
  "=?" +
  charset.to_owned() +
  "?" +
  encoding.letter().to_string() +
  "?" +
  word_body(data, encoding) +
  "?="
}

///|
/// One encoded word, however long it comes out.
///
/// ```mbt check
/// test {
///   let word = @moonmime.encode_word("Café") catch { _ => "" }
///   inspect(@moonmime.decode_words(word[:]), content="Café")
/// }
/// ```
pub fn encode_word(
  text : StringView,
  charset~ : String = "utf-8",
  encoding~ : WordEncoding = WordEncoding::Base64,
  charsets? : Map[String, &Charset],
) -> String raise Refused {
  let data = encode_charset(name=charset, text~, charsets?)
  wrap_word(data[:], charset[:], encoding)
}

///|
/// How many octets one word may carry. `=?charset?B?` and `?=` are chrome and
/// count against the 75 too, so what is left is what the encoded octets spend.
fn word_capacity(charset : StringView, encoding : WordEncoding) -> Int32 {
  let budget = 75 - (7 + charset.length())
  let room = if budget < 1 { 1 } else { budget }
  match encoding {
    WordEncoding::Base64 => {
      let per = room / 4 * 3
      if per < 3 {
        3
      } else {
        per
      }
    }
    WordEncoding::QuotedPrintable =>
      // One octet costs up to three characters; stepping by the budget rather
      // than by threes keeps mostly-safe text readable.
      if room < 3 {
        1
      } else {
        room
      }
  }
}

///|
/// Whether `b` is a UTF-8 continuation octet (`10xxxxxx`). A slice that ends on
/// one of these has cut a multi-octet character in half, which RFC 2047 §5
/// forbids, so `word_slices` backs the boundary up until it lands on a lead
/// octet.
fn is_continuation_byte(b : Byte) -> Bool {
  let n = byte_code(b)
  n >= 0x80 && n <= 0xBF
}

///|
/// Split the octets into pieces each small enough for one word, never letting
/// the Q form run past what the budget allows. UTF-8 pieces are cut on a
/// character boundary so no encoded word carries half a character.
fn word_slices(
  data : BytesView,
  charset : StringView,
  encoding : WordEncoding,
) -> Array[Bytes] {
  let step = word_capacity(charset, encoding)
  let utf8 = {
    let name = lower(charset)
    name == "utf-8" || name == "utf8"
  }
  let slices : Array[Bytes] = []
  match encoding {
    WordEncoding::Base64 => {
      let mut at = 0
      while at < data.length() {
        let mut stop = at + step
        if stop > data.length() {
          stop = data.length()
        }
        if utf8 {
          while stop < data.length() &&
                stop > at &&
                is_continuation_byte(data.at(stop)) {
            stop = stop - 1
          }
        }
        slices.push(data[at:stop].to_owned())
        at = stop
      }
    }
    WordEncoding::QuotedPrintable => {
      let mut start = 0
      while start < data.length() {
        let mut stop = start
        let mut width = 0
        while stop < data.length() {
          let piece = q_word_encode(data[stop:stop + 1]).length()
          if width + piece > step && stop > start {
            break
          }
          width = width + piece
          stop = stop + 1
        }
        if stop == start {
          stop = if start + 1 > data.length() {
            data.length()
          } else {
            start + 1
          }
        }
        slices.push(data[start:stop].to_owned())
        start = stop
      }
    }
  }
  slices
}

///|
/// A header value written as encoded words, splitting whenever the next word
/// would run past `max`.
///
/// Text that is already printable US-ASCII goes back unchanged: it needs no
/// encoding, and writing it plainly is what keeps `Subject: Hello` readable in
/// a raw view.
pub fn encode_words(
  text : StringView,
  charset~ : String = "utf-8",
  encoding~ : WordEncoding = WordEncoding::Base64,
  column~ : Int32 = 0,
  max~ : Int32 = 76,
  charsets? : Map[String, &Charset],
) -> String raise Refused {
  if text.is_empty() || is_ascii_printable(text) {
    return text.to_owned()
  }
  let data = encode_charset(name=charset, text~, charsets?)
  let slices = word_slices(data[:], charset[:], encoding)
  let out = StringBuilder()
  let mut col = column
  let mut first = true
  for slice in slices {
    let word = wrap_word(slice[:], charset[:], encoding)
    if first {
      first = false
    } else if col + 1 + word.length() <= max {
      out.write_char(' ')
      col = col + 1
    } else {
      out.write_string("\r\n ")
      col = 1
    }
    out.write_string(word)
    col = col + word.length()
  }
  out.to_string()
}

///|
/// An encoded word seen in `chars` starting at `at`: its charset, its encoding,
/// the octets its body held, and where the next character begins. `None` when
/// the shape is not an encoded word, which is how a stray `=?` inside ordinary
/// text stays ordinary text.
fn take_word(
  chars : ArrayView[Char],
  at : Int32,
) -> (String, WordEncoding, Bytes, Int32)? {
  let n = chars.length()
  if at + 2 > n {
    return None
  }
  if chars[at] != '=' || chars[at + 1] != '?' {
    return None
  }
  let name = StringBuilder()
  let mut i = at + 2
  while i < n {
    let c = chars[i]
    if c == '?' {
      break
    }
    if is_wsp(c) {
      return None
    }
    name.write_char(c)
    i = i + 1
  }
  let charset = name.to_string()
  if charset.is_empty() {
    return None
  }
  if i + 3 >= n {
    return None
  }
  let encoding = match chars[i + 1] {
    'B' | 'b' => Some(WordEncoding::Base64)
    'Q' | 'q' => Some(WordEncoding::QuotedPrintable)
    _ => None
  }
  if encoding is None {
    return None
  }
  let encoding = encoding.unwrap()
  if chars[i + 2] != '?' {
    return None
  }
  let body = StringBuilder()
  let mut j = i + 3
  while j + 1 < n {
    if chars[j] == '?' && chars[j + 1] == '=' {
      break
    }
    body.write_char(chars[j])
    j = j + 1
  }
  if j + 1 >= n {
    return None
  }
  let text = body.to_string()
  let octets = match encoding {
    WordEncoding::Base64 =>
      Some(@base64.decode(text[:], padding=true)) catch {
        _ => None
      }
    WordEncoding::QuotedPrintable =>
      try {
        let mut replaced = ""
        for c in text {
          replaced = replaced + (if c == '_' { " " } else { c.to_string() })
        }
        Some(@qp.decode(@utf8.encode(replaced)[:]))
      } catch {
        _ => None
      }
  }
  if octets is None {
    return None
  }
  Some((charset, encoding, octets.unwrap(), j + 2))
}

///|
/// Undo what `encode_words` did, and what every other mail library did too:
/// encoded words are the one corner of a header everybody writes the same way.
///
/// Whitespace between two adjacent encoded words disappears, because that was
/// folding and not content; whitespace next to ordinary text stays put.
///
/// ```mbt check
/// test {
///   inspect(@moonmime.decode_words("=?utf-8?B?Q2Fmw6k=?="), content="Café")
/// }
/// ```
pub fn decode_words(
  value : StringView,
  charsets? : Map[String, &Charset],
) -> String {
  let chars = value.to_owned().to_array()
  let n = chars.length()
  let out = StringBuilder()
  let mut pending = 0
  let mut after_word = false
  let mut i = 0
  while i < n {
    let c = chars[i]
    if c == '=' && i + 1 < n && chars[i + 1] == '?' {
      match take_word(chars[:], i) {
        Some((charset, _encoding, octets, stop)) => {
          if !after_word {
            for _k in 0..<pending {
              out.write_char(' ')
            }
          }
          pending = 0
          let text = decode_charset(name=charset[:], data=octets[:], charsets?) catch {
            _ => latin1_text(octets[:])
          }
          out.write_string(text)
          after_word = true
          i = stop
          continue
        }
        None => {
          write_spaces(out, pending)
          pending = 0
          out.write_char(c)
          after_word = false
          i = i + 1
          continue
        }
      }
    }
    if is_wsp(c) || c == '\r' || c == '\n' {
      pending = pending + 1
      i = i + 1
      continue
    }
    write_spaces(out, pending)
    pending = 0
    out.write_char(c)
    after_word = false
    i = i + 1
  }
  write_spaces(out, pending)
  out.to_string()
}

///|
fn write_spaces(out : StringBuilder, count : Int32) -> Unit {
  let mut left = count
  while left > 0 {
    out.write_char(' ')
    left = left - 1
  }
}
