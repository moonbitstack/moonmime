// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
fn text_of(value : String) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < value.length(); i = i + 1 {
    out.push((value.at(i).to_int() & 0xFF).to_byte())
  }
  Bytes::from_array(out)
}

///|
/// A body handed over in equal chunks, counting the octets it has given away.
///
/// The count is what a bound is measured against: what a reader pulled is the
/// only thing a source can be asked about afterwards.
struct Metered {
  body : Bytes
  size : Int32
  mut at : Int32
  mut given : Int32
}

///|
fn Metered::of(body : String, size : Int32) -> Metered {
  { body: text_of(body), size, at: 0, given: 0, }
}

///|
impl @moonmime.Source for Metered with fn next(self) {
  if self.at >= self.body.length() {
    return None
  }
  let to = if self.at + self.size > self.body.length() {
    self.body.length()
  } else {
    self.at + self.size
  }
  let chunk : Array[Byte] = []
  for i = self.at; i < to; i = i + 1 {
    chunk.push(self.body[i])
  }
  self.given = self.given + (to - self.at)
  self.at = to
  Some(Bytes::from_array(chunk))
}

///|
/// A body handed over piece by piece, counting what it has given away. Unlike
/// `Metered` it can hold a body too large to want in memory.
struct Pieces {
  pieces : Array[Bytes]
  mut at : Int32
  mut given : Int32
}

///|
fn Pieces::of(pieces : Array[String]) -> Pieces {
  { pieces: pieces.map(text_of), at: 0, given: 0, }
}

///|
impl @moonmime.Source for Pieces with fn next(self) {
  if self.at >= self.pieces.length() {
    return None
  }
  let piece = self.pieces[self.at]
  self.at = self.at + 1
  self.given = self.given + piece.length()
  Some(piece)
}

///|
/// A `multipart/mixed` body as an email client writes one.
let mail : String = "--b\r\n" +
  "Content-Type: text/plain\r\n" +
  "\r\n" +
  "hola\r\n" +
  "--b\r\n" +
  "Content-Type: text/html\r\n" +
  "Content-Transfer-Encoding: 8bit\r\n" +
  "\r\n" +
  "<b>hola</b>\r\n" +
  "--b--\r\n"

///|
/// Every part of a body, read by the streaming reader.
fn read_all(
  reader : @moonmime.PartsReader,
) -> Array[@moonmime.Part] raise @moonmime.Refused {
  let parts : Array[@moonmime.Part] = []
  let mut more = true
  while more {
    match reader.next_part() {
      Some(head) => {
        let body : Array[Byte] = []
        let mut reading = true
        while reading {
          match reader.read() {
            Some(chunk) =>
              for i = 0; i < chunk.length(); i = i + 1 {
                body.push(chunk[i])
              }
            None => reading = false
          }
        }
        parts.push({ headers: head.headers, body: Bytes::from_array(body), })
      }
      None => more = false
    }
  }
  parts
}

///|
/// The current part's body, gathered from as many chunks as it arrives in.
fn drain(reader : @moonmime.PartsReader) -> Bytes raise @moonmime.Refused {
  let body : Array[Byte] = []
  let mut reading = true
  while reading {
    match reader.read() {
      Some(chunk) =>
        for i = 0; i < chunk.length(); i = i + 1 {
          body.push(chunk[i])
        }
      None => reading = false
    }
  }
  Bytes::from_array(body)
}

///|
test "a part's head arrives before its body" {
  let reader = @moonmime.PartsReader::new(Metered::of(mail, 4), "b")
  let head = reader.next_part().unwrap()
  assert_eq(head.header("content-type"), Some("text/plain"))
  assert_eq(head.content_type().unwrap().essence, "text/plain")
  assert_eq(head.disposition(), None)
  assert_eq(drain(reader), b"hola")
  let second = reader.next_part().unwrap()
  assert_eq(second.header("content-type"), Some("text/html"))
  assert_eq(second.header("content-transfer-encoding"), Some("8bit"))
}

///|
test "chunk boundaries do not change what is read" {
  let whole = @moonmime.multipart(text_of(mail)[:], "b")
  for size in [1, 2, 3, 5, 7, 11, 64] {
    let parts = read_all(
      @moonmime.PartsReader::new(Metered::of(mail, size), "b"),
    ) catch {
      e => fail("a body of chunks of \{size} was refused: \{e.to_repr()}")
    }
    assert_eq(parts.length(), whole.length())
    for i = 0; i < parts.length(); i = i + 1 {
      assert_eq(parts[i].headers, whole[i].headers)
      assert_eq(parts[i].body, whole[i].body)
    }
  }
}

///|
test "the streaming reader and the one-shot reader agree" {
  let bodies : Array[String] = [
    mail,
    // a preamble and an epilogue
     "preamble\r\n--b\r\nContent-Type: text/plain\r\n\r\nhi\r\n--b--\r\nepilogue",
    // a part with no header field at all
     "--b\r\n\r\nbare\r\n--b--\r\n",
    // a folded header, as a generator writes a long one
     "--b\r\nContent-Disposition: form-data; name=\"doc\";\r\n filename=\"a.txt\"\r\n\r\ndoc\r\n--b--\r\n",
    // a body with no parts
     "--b--\r\n",
    // a body that holds the delimiter's own stem without being a delimiter
     "--b\r\nContent-Type: text/plain\r\n\r\n--b-not-a-delimiter\r\n--b--\r\n",
    // a part whose body is empty
     "--b\r\nContent-Type: text/plain\r\n\r\n\r\n--b--\r\n",
    // a part that carries the delimiter's stem across the end of a chunk
     "--b\r\nContent-Type: text/plain\r\n\r\none--b--two\r\n--b--\r\n",
  ]
  for source in bodies {
    let whole = @moonmime.multipart(text_of(source)[:], "b")
    for size in [1, 4, 9] {
      let parts = read_all(
        @moonmime.PartsReader::new(Metered::of(source, size), "b"),
      ) catch {
        e => fail("a body of chunks of \{size} was refused: \{e.to_repr()}")
      }
      assert_eq(parts.length(), whole.length())
      for i = 0; i < parts.length(); i = i + 1 {
        assert_eq(parts[i].headers, whole[i].headers)
        assert_eq(parts[i].body, whole[i].body)
      }
    }
  }
}

///|
test "a part over its bound is refused where it is crossed" {
  // Seven octets of head, then a body of sixteen-octet pieces: the bound is
  // crossed in the sixty-third of them, and the pieces after it are never
  // asked for.
  let pieces : Array[String] = ["--b\r\n\r\n"]
  for i = 0; i < 200; i = i + 1 {
    pieces.push("0123456789abcdef")
  }
  let source = Pieces::of(pieces)
  let reader = @moonmime.PartsReader::new(
    source,
    "b",
    limits=@moonmime.Limits::new(parts=4, part_size=1000),
  ) catch {
    e => fail("the boundary was refused: \{e.to_repr()}")
  }
  let _ = reader.next_part().unwrap()
  let mut crossed = 0
  let mut reading = true
  try {
    while reading {
      match reader.read() {
        Some(_) => ()
        None => reading = false
      }
    }
  } catch {
    e =>
      match e {
        @moonmime.Part(limit~, got~) => {
          assert_eq(limit, 1000)
          crossed = got
          reading = false
        }
        _ => fail("a part over its bound was not refused: \{e.to_repr()}")
      }
  } noraise {
    _ => ()
  }
  assert_eq(crossed > 1000, true)
  // What the reader pulled past the bound is the piece that crossed it, and no
  // more: the head and the bound plus one piece.
  assert_eq(source.given <= 7 + 1000 + 16, true)
}

///|
test "a part count over the bound is refused" {
  let reader = @moonmime.PartsReader::over(
    text_of(mail)[:],
    "b",
    limits=@moonmime.Limits::new(parts=1),
  )
  let head = reader.next_part().unwrap()
  assert_eq(head.header("content-type"), Some("text/plain"))
  assert_eq(reader.read().unwrap(), b"hola")
  assert_eq(reader.read() is None, true)
  try reader.next_part() |> ignore catch {
    e => assert_eq(e, @moonmime.Parts(limit=1))
  } noraise {
    _ => fail("a second part passed a limit of one")
  }
}

///|
test "a body left unread is discarded before the next head" {
  let reader = @moonmime.PartsReader::over(text_of(mail)[:], "b")
  let first = reader.next_part().unwrap()
  assert_eq(first.header("content-type"), Some("text/plain"))
  let second = reader.next_part().unwrap()
  assert_eq(second.header("content-type"), Some("text/html"))
  assert_eq(reader.read().unwrap(), b"<b>hola</b>")
  assert_eq(reader.next_part() is None, true)
}

///|
test "a body left unread still counts against the bound" {
  let body = "--b\r\nContent-Type: text/plain\r\n\r\n12345678\r\n" +
    "--b\r\nContent-Type: text/plain\r\n\r\n9\r\n--b--\r\n"
  let reader = @moonmime.PartsReader::over(
    text_of(body)[:],
    "b",
    limits=@moonmime.Limits::new(part_size=4),
  )
  let _ = reader.next_part().unwrap()
  try reader.next_part() |> ignore catch {
    e => assert_eq(e, @moonmime.Part(limit=4, got=8))
  } noraise {
    _ => fail("an eight-octet body passed a limit of four")
  }
}

///|
test "strict refuses a body that stops making sense at the same offset" {
  let broken = "--b\r\nContent-Type: text/plain\r\n"
  let mut one_shot = 0
  try
    @moonmime.multipart(text_of(broken)[:], "b", strict=true) |> ignore
  catch {
    e =>
      match e {
        @moonmime.Malformed(at~) => one_shot = at
        _ => fail("a truncated body was not refused as malformed")
      }
  } noraise {
    _ => fail("a truncated body passed in strict mode")
  }
  let reader = @moonmime.PartsReader::over(text_of(broken)[:], "b", strict=true)
  try reader.next_part() |> ignore catch {
    e => assert_eq(e, @moonmime.Malformed(at=one_shot))
  } noraise {
    _ => fail("the streaming reader passed a truncated body in strict mode")
  }
}

///|
test "a body that ends mid-part keeps the parts before it" {
  let broken = "--b\r\nContent-Type: text/plain\r\n\r\nhola\r\n" +
    "--b\r\nContent-Type: text/html\r\n"
  let reader = @moonmime.PartsReader::over(text_of(broken)[:], "b")
  let head = reader.next_part().unwrap()
  assert_eq(head.header("content-type"), Some("text/plain"))
  assert_eq(reader.read().unwrap(), b"hola")
  assert_eq(reader.next_part() is None, true)
  assert_eq(@moonmime.multipart(text_of(broken)[:], "b").length(), 1)
}

///|
test "a body that is only a closing delimiter has no parts" {
  let reader = @moonmime.PartsReader::over(b"--b--\r\n", "b")
  assert_eq(reader.next_part() is None, true)
  assert_eq(reader.next_part() is None, true)
}

///|
test "an empty body has no parts" {
  let reader = @moonmime.PartsReader::over(b"", "b")
  assert_eq(reader.next_part() is None, true)
}

///|
test "a boundary that cannot delimit is refused" {
  try @moonmime.PartsReader::over(b"--b--\r\n", "a b ") |> ignore catch {
    e => assert_eq(e, @moonmime.Boundary(got="a b "))
  } noraise {
    _ => fail("a boundary ending in a space was accepted")
  }
}

///|
test "the reader stops pulling once the last delimiter is read" {
  let source = Metered::of(mail, 5)
  let reader = @moonmime.PartsReader::new(source, "b")
  let parts = read_all(reader) catch {
    e => fail("the body was refused: \{e.to_repr()}")
  }
  assert_eq(parts.length(), 2)
  // The closing delimiter ends the body; the epilogue behind it belongs to
  // nobody, and a reader that pulled for it would wait on a socket for octets
  // that are not part of anything.
  assert_eq(source.given <= text_of(mail).length(), true)
}

///|
test "a head carries the headers a part does" {
  let reader = @moonmime.PartsReader::over(
    b"--b\r\ncontent-id: <20260101.photo@example>\r\ncontent-type: text/plain\r\n\r\nhola\r\n--b--\r\n",
    "b",
  )
  let head = reader.next_part().unwrap()
  assert_eq(head.content_id(), Some("20260101.photo@example"))
  assert_eq(head.content_type().unwrap().essence, "text/plain")
  assert_eq(head.header("content-id"), Some("<20260101.photo@example>"))
}

///|
test "a head is read without the whole body being pulled" {
  let source = Metered::of(mail, 8)
  let reader = @moonmime.PartsReader::new(source, "b")
  let head = reader.next_part().unwrap()
  assert_eq(head.header("content-type"), Some("text/plain"))
  assert_eq(source.given < text_of(mail).length(), true)
}
