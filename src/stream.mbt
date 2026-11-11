// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A body arriving in pieces: the next octets, and `None` once there are none.
///
/// The chunk is the source's to size — a socket read, a slice of a file, a
/// window of a buffer. A reader asks for one only when it needs the octets in
/// it, which is what lets a bound stop a body where it is crossed instead of
/// after the whole of it has been read.
///
/// ```mbt check
/// test {
///   let source : &@moonmime.Source = @moonmime.Chunks::new(b"--b--\r\n")
///   match source.next() {
///     Some(chunk) => assert_eq(chunk, b"--b--\r\n")
///     None => fail("the body was not handed over")
///   }
///   assert_eq(source.next() is None, true)
/// }
/// ```
pub(open) trait Source {
  fn next(Self) -> Bytes?
}

///|
/// A body held whole, handed over as one chunk.
///
/// It is the adapter for a caller that already has the octets: streaming from
/// memory and streaming from a socket reach the reader the same way.
struct Chunks {
  body : Bytes
  mut given : Bool
}

///|
/// The body `body` holds, as a source that hands it over once.
pub fn Chunks::new(body : BytesView) -> Chunks {
  { body: body.to_owned(), given: false, }
}

///|
pub extend Chunks with Source::{next}

///|
pub impl Source for Chunks with fn next(self) {
  if self.given {
    None
  } else {
    self.given = true
    Some(self.body)
  }
}

// ------------------------------------------------------------------ the window

///|
/// The octets pulled and not yet consumed.
///
/// What is consumed is dropped, so the window holds one chunk plus the octets a
/// delimiter needs to be recognised across two chunks — never the body.
priv struct Feed {
  source : &Source
  mut buf : Array[Byte]
  mut start : Int32
  mut consumed : Int32
  mut ended : Bool
}

///|
fn Feed::new(source : &Source) -> Feed {
  { source, buf: [], start: 0, consumed: 0, ended: false, }
}

///|
/// How many octets the window holds.
fn Feed::length(self : Feed) -> Int32 {
  self.buf.length() - self.start
}

///|
/// Pull one chunk. `false` at the end of the body.
fn Feed::pull(self : Feed) -> Bool {
  while !self.ended {
    match self.source.next() {
      Some(chunk) =>
        if chunk.length() > 0 {
          for i = 0; i < chunk.length(); i = i + 1 {
            self.buf.push(chunk[i])
          }
          return true
        }
      None => self.ended = true
    }
  }
  false
}

///|
/// Pull until the window holds `n` octets, or the body ends.
fn Feed::fill(self : Feed, n : Int32) -> Bool {
  while self.length() < n {
    if !self.pull() {
      return false
    }
  }
  true
}

///|
fn Feed::drop(self : Feed, n : Int32) -> Unit {
  self.start = self.start + n
  self.consumed = self.consumed + n
  // A body is read by dropping from the front, so the consumed prefix is
  // compacted once it is the larger half; without that the window would grow
  // with the body it is supposed to stream.
  if self.start > 4096 && self.start * 2 > self.buf.length() {
    let rest : Array[Byte] = []
    for i = self.start; i < self.buf.length(); i = i + 1 {
      rest.push(self.buf[i])
    }
    self.buf = rest
    self.start = 0
  }
}

///|
fn Feed::take(self : Feed, n : Int32) -> Bytes {
  let out : Array[Byte] = []
  for i = 0; i < n; i = i + 1 {
    out.push(self.buf[self.start + i])
  }
  Bytes::from_array(out)
}

///|
/// Whether the window begins with `needle`.
fn Feed::starts(self : Feed, needle : BytesView) -> Bool {
  if self.length() < needle.length() {
    return false
  }
  for j = 0; j < needle.length(); j = j + 1 {
    if self.buf[self.start + j] != needle[j] {
      return false
    }
  }
  true
}

///|
/// Where `needle` stands in the window, from `from` on; `None` if it is not
/// there yet.
fn Feed::find(self : Feed, needle : BytesView, from : Int32) -> Int32? {
  let last = self.length() - needle.length()
  let mut i = from
  while i <= last {
    let mut same = true
    for j = 0; j < needle.length(); j = j + 1 {
      if self.buf[self.start + i + j] != needle[j] {
        same = false
        break
      }
    }
    if same {
      return Some(i)
    }
    i = i + 1
  }
  None
}

// ---------------------------------------------------------------- the reader

///|
/// The head of a part: its header fields, handed over before its body.
///
/// What a reader sees first, and all it needs to decide whether it wants the
/// body at all — a form field can be dropped on its name without its octets
/// having been read.
#derive(Eq, Debug)
pub(all) struct PartHead {
  headers : Array[(String, String)]
}

///|
pub extend PartHead with Eq::{equal, not_equal}

///|
pub extend PartHead with Debug::{to_repr}

///|
/// One of the part's own headers, by lowercased name.
pub fn PartHead::header(self : PartHead, name : StringView) -> String? {
  header_of(self.headers, name)
}

///|
/// The part's `Content-Type`, parsed; `None` when it has none.
pub fn PartHead::content_type(self : PartHead) -> MediaType? {
  match self.header("content-type") {
    Some(value) => Some(media_type(value[:]))
    None => None
  }
}

///|
/// The part's `Content-Disposition`, parsed; `None` when it has none.
pub fn PartHead::disposition(self : PartHead) -> Disposition? {
  match self.header("content-disposition") {
    Some(value) => Some(Disposition::parse(value[:]))
    None => None
  }
}

///|
/// The part's `Content-ID` without its angle brackets, which is the form the
/// `start` parameter of `multipart/related` names it by; `None` when it has
/// none.
pub fn PartHead::content_id(self : PartHead) -> String? {
  match self.header("content-id") {
    Some(value) => Some(content_id_of(value[:]))
    None => None
  }
}

///|
/// Where the reader stands.
#derive(Eq)
priv enum Phase {
  Preamble
  Head
  Body
  Done
}

///|
/// Reads a multipart body as it arrives: a part's header fields first, then its
/// body, one chunk at a time.
///
/// The bound is part of the reading rather than a check afterwards: a part that
/// passes its size is refused where it is crossed, and the octets after it are
/// never pulled. What is already handed over cannot be taken back, so an
/// unread remainder of a part is discarded — and still counted — before the
/// next head is read.
///
/// ```mbt check
/// test {
///   let reader = @moonmime.PartsReader::over(
///     b"--b\r\nContent-Type: text/plain\r\n\r\nhola\r\n--b--\r\n", "b",
///   )
///   let head = reader.next_part().unwrap()
///   inspect(head.header("content-type").unwrap_or(""), content="text/plain")
///   inspect(reader.read().unwrap(), content="b\"hola\"")
///   inspect(reader.read() is None, content="true")
///   inspect(reader.next_part() is None, content="true")
/// }
/// ```
struct PartsReader {
  feed : Feed
  needle : Bytes
  boundary : String
  limits : Limits
  strict : Bool
  mut phase : Phase
  mut head_at : Int32
  mut body_seen : Int32
  mut parts : Int32
}

///|
/// Read `boundary`-delimited parts from `source`.
///
/// The boundary is refused when it cannot delimit a body at all — the same
/// bchars and the same 70-octet limit a written body is held to.
pub fn PartsReader::new(
  source : &Source,
  boundary : StringView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> PartsReader raise Refused {
  let boundary = boundary.to_owned()
  guard is_boundary(boundary[:]) else { raise Boundary(got=boundary) }
  {
    feed: Feed::new(source),
    needle: ascii("--" + boundary),
    boundary,
    limits,
    strict,
    phase: Phase::Preamble,
    head_at: 0,
    body_seen: 0,
    parts: 0,
  }
}

///|
/// Read parts out of a body that is already in hand.
pub fn PartsReader::over(
  body : BytesView,
  boundary : StringView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> PartsReader raise Refused {
  PartsReader::new(Chunks::new(body), boundary, limits~, strict~)
}

///|
/// The boundary the parts are delimited by.
pub fn PartsReader::boundary(self : PartsReader) -> String {
  self.boundary
}

///|
/// The next part's head, or `None` once the body has ended.
///
/// A body the caller did not read to its end is discarded first, and its octets
/// are counted against the bound like any other.
pub fn PartsReader::next_part(self : PartsReader) -> PartHead? raise Refused {
  if self.phase == Phase::Body {
    let mut more = self.read() is Some(_)
    while more {
      more = self.read() is Some(_)
    }
  }
  if self.phase == Phase::Done {
    return None
  }
  if self.phase == Phase::Preamble {
    if !self.skip_to_delimiter() {
      self.phase = Phase::Done
      return None
    }
    self.after_delimiter()
    if self.phase == Phase::Done {
      return None
    }
  }
  let headers = match self.read_head() {
    Some(headers) => headers
    None => return None
  }
  if self.parts == self.limits.parts {
    raise Parts(limit=self.limits.parts)
  }
  self.parts = self.parts + 1
  self.body_seen = 0
  self.phase = Phase::Body
  Some({ headers, })
}

///|
/// The next octets of the current part's body, or `None` at its end.
///
/// A part with an empty body answers `None` on the first call; the delimiter
/// after it has already been consumed by then, so the next `next_part` reads a
/// head rather than looking for a boundary it passed.
pub fn PartsReader::read(self : PartsReader) -> Bytes? raise Refused {
  if self.phase != Phase::Body {
    return None
  }
  let needle = self.needle[:]
  let n = needle.length()
  let mut answer : Bytes? = None
  let mut reading = true
  while reading {
    match self.feed.find(needle, 0) {
      Some(at) => {
        // The octets right before a delimiter are its own CRLF; when the
        // delimiter stands at the very start of the body there are none, which
        // is what the clamp keeps true.
        let crlf = if at >= 2 { 2 } else { 0 }
        let length = at - crlf
        self.count(length)
        reading = false
        if length == 0 {
          self.feed.drop(at)
          self.after_delimiter()
        } else {
          let chunk = self.feed.take(length)
          self.feed.drop(length + crlf)
          self.after_delimiter()
          answer = Some(chunk)
        }
      }
      None => {
        // Everything but the octets a delimiter could be half-way through is
        // body, and goes out as it stands. The delimiter proper is its own CRLF
        // and then the boundary, so the octets held back are one more than the
        // needle: the CRLF before a delimiter that straddles two chunks is not
        // content either.
        let length = self.feed.length() - (n + 1)
        if length > 0 {
          self.count(length)
          let chunk = self.feed.take(length)
          self.feed.drop(length)
          answer = Some(chunk)
          reading = false
        } else if !self.feed.pull() {
          // The body ended with no delimiter after it. What was handed over
          // stays handed over; the part is over either way.
          if self.strict {
            raise Malformed(at=self.head_at)
          }
          self.phase = Phase::Done
          reading = false
        }
      }
    }
  }
  answer
}

///|
/// Count `n` octets of the current part's body, and refuse the part when they
/// carry it past its bound — before they are handed over, so a body over the
/// bound is never read further than the chunk that crossed it.
fn PartsReader::count(self : PartsReader, n : Int32) -> Unit raise Refused {
  if self.body_seen + n > self.limits.part_size {
    raise Part(limit=self.limits.part_size, got=self.body_seen + n)
  }
  self.body_seen = self.body_seen + n
}

///|
/// Move the window to the next delimiter, dropping what stands before it.
fn PartsReader::skip_to_delimiter(self : PartsReader) -> Bool {
  let n = self.needle.length()
  let mut found = false
  let mut searching = true
  while searching {
    match self.feed.find(self.needle[:], 0) {
      Some(at) => {
        self.feed.drop(at)
        found = true
        searching = false
      }
      None => {
        // Everything but the octets a delimiter could be half-way through is
        // preamble, and preamble is dropped where it stands.
        let length = self.feed.length()
        if length > n - 1 {
          self.feed.drop(length - (n - 1))
        }
        if !self.feed.pull() {
          searching = false
        }
      }
    }
  }
  found
}

///|
/// Consume the delimiter the window begins with, then read what follows it: a
/// closing `--`, the CRLF that opens the next head, or a head that starts right
/// there.
fn PartsReader::after_delimiter(self : PartsReader) -> Unit {
  self.feed.drop(self.needle.length())
  self.feed.fill(2) |> ignore
  if self.feed.starts(b"--"[:]) {
    self.feed.drop(2)
    self.phase = Phase::Done
    return
  }
  if self.feed.starts(b"\r\n"[:]) {
    self.feed.drop(2)
  }
  self.head_at = self.feed.consumed
  self.phase = Phase::Head
}

///|
/// The current part's header block, or `None` when the body stops making sense
/// before one arrives.
fn PartsReader::read_head(
  self : PartsReader,
) -> Array[(String, String)]? raise Refused {
  self.feed.fill(2) |> ignore
  // A part may carry no header field at all, and the empty line that ends the
  // block is then the first thing after the delimiter.
  if self.feed.starts(b"\r\n"[:]) {
    self.feed.drop(2)
    return Some([])
  }
  match self.collect_head() {
    Some(block) => Some(part_headers(block[:]))
    None => None
  }
}

///|
fn PartsReader::collect_head(self : PartsReader) -> Bytes? raise Refused {
  let mut block : Bytes? = None
  let mut searching = true
  while searching {
    match self.feed.find(b"\r\n\r\n"[:], 0) {
      Some(at) => {
        searching = false
        // A delimiter standing before the blank line means the head never
        // arrived: the part stops at the head's own offset.
        let split = match self.feed.find(self.needle[:], 0) {
          Some(delimiter) => delimiter < at
          None => false
        }
        if split {
          block = self.broken()
        } else {
          block = Some(self.feed.take(at))
          self.feed.drop(at + 4)
        }
      }
      None => {
        // A head longer than a part is a body that would not fit either, and
        // the bound is what keeps a hostile header block from being held whole.
        let head = self.feed.consumed - self.head_at + self.feed.length()
        if head > self.limits.part_size {
          raise Part(limit=self.limits.part_size, got=head)
        }
        if !self.feed.pull() {
          searching = false
          block = self.broken()
        }
      }
    }
  }
  block
}

///|
/// The body stopped making sense at the head of the part being read.
fn PartsReader::broken(self : PartsReader) -> Bytes? raise Refused {
  if self.strict {
    raise Malformed(at=self.head_at)
  }
  self.phase = Phase::Done
  None
}
