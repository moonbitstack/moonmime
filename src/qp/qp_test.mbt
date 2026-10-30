// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
test "qp_encode leaves safe text alone" {
  let out = @qp.encode(@utf8.encode("Hello, World!")[:])
  inspect(@utf8.decode_lossy(out[:]), content="Hello, World!")
}

///|
test "qp_encode quotes equals and high octets" {
  inspect(@utf8.decode_lossy(@qp.encode(b"a=b")[:]), content="a=3Db")
  inspect(@utf8.decode_lossy(@qp.encode(b"\xe9")[:]), content="=E9")
}

///|
test "qp_encode quotes trailing whitespace on a line" {
  inspect(@utf8.decode_lossy(@qp.encode(b"a \r\nb")[:]), content="a=20\r\nb")
}

///|
test "qp_encode normalises mixed line endings to CRLF" {
  inspect(@utf8.decode_lossy(@qp.encode(b"a\nb\rc")[:]), content="a\r\nb\r\nc")
}

///|
test "qp_decode undoes hex escapes and soft breaks" {
  let eq = @qp.decode(b"=3D") catch { _ => b"" }
  inspect(@utf8.decode_lossy(eq[:]), content="=")
  let soft = @qp.decode(b"a=\r\nb") catch { _ => b"" }
  inspect(@utf8.decode_lossy(soft[:]), content="ab")
}

///|
test "qp round trip preserves octets" {
  let cases : Array[Bytes] = [
    b"",
    b"plain ascii",
    b"a=b",
    b"\xe9\xff",
    b"line one\r\nline two",
    @utf8.encode("Café ☕"),
  ]
  for original in cases {
    let back = @qp.decode(@qp.encode(original[:])[:]) catch { _ => b"" }
    inspect(back == original, content="true")
  }
}

///|
test "qp round trip a line that needs a soft break" {
  let long = @utf8.encode(
    "This line is long enough that quoted-printable must insert a soft break somewhere inside it.",
  )
  let back = @qp.decode(@qp.encode(long[:])[:]) catch { _ => b"" }
  inspect(back == long, content="true")
}

///|
test "qp_decode strict rejects a broken escape" {
  let raised = try {
    let _ = @qp.decode(b"=zz", strict=true)
    false
  } catch {
    _ => true
  }
  inspect(raised, content="true")
}
