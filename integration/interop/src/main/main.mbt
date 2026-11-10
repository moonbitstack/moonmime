// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The exchange program the interop check drives.
//
// It is not part of the library and nothing imports it: it exists so that one
// set of cases can be written here and read by another implementation, and
// written there and read here, with the values compared after each leg. Bodies
// go through the filesystem because a body is octets, and because every leg
// hands a whole body over at once.
//
//     write <directory>   every <id>.sheet becomes <id>.out.body, <id>.out.type
//     read  <directory>   every <id>.body, with its <id>.sheet, becomes
//                         <id>.out.read
//
// A sheet is one case. One clause a line, and every payload base64 so that a
// space separates the fields of a line and nothing else can:
//
//     kind form-data                     kind mixed
//     boundary ----edge                  (absent: the writer chooses one)
//     field <name> <value>
//     file <name> <filename> <content-type> <content>
//     part <headers> <body>              headers are "name: value", CRLF apart
//
// A report is one line per value read, in the same notation:
//
//     field <name> <value>
//     file <name> <filename> <content-type> <content>
//     part <content-type> <body>

///|
fn main {
  let argv = arguments(@env.args())
  match argv {
    ["write", directory] =>
      for_each_sheet(directory, sheet => write_case(directory, sheet))
    ["read", directory] =>
      for_each_sheet(directory, sheet => read_case(directory, sheet))
    _ => refuse("usage: interop write|read <directory>")
  }
}

///|
/// The arguments from the mode word on, which is how `moon run` hands them over:
/// the path of the program comes first and is not interesting.
fn arguments(argv : Array[String]) -> Array[String] {
  let rest : Array[String] = []
  let mut found = false
  for argument in argv {
    if found {
      rest.push(argument)
    } else if argument == "write" || argument == "read" {
      found = true
      rest.push(argument)
    }
  }
  rest
}

///|
fn[T] refuse(why : String) -> T {
  println("interop: \{why}")
  @env.exit(2)
}

///|
/// One case, as its sheet says it.
struct Sheet {
  id : String
  kind : @moonmime.MultipartKind
  boundary : String
  fields : Array[@moonmime.Field]
  files : Array[@moonmime.Upload]
  parts : Array[@moonmime.Part]
}

// ------------------------------------------------------------------ the legs

///|
/// Write the case as this library frames it: the octets to `<id>.out.body` and
/// the `Content-Type` that goes with them to `<id>.out.type`.
fn write_case(directory : String, sheet : Sheet) -> Unit {
  let written = framed(sheet) catch {
    @moonmime.Boundary(got~) =>
      return refuse("case \{sheet.id}: the boundary \{got} cannot delimit it")
    refused => return refuse("case \{sheet.id}: \{refused.to_repr()}")
  }
  write_bytes(join(directory, sheet.id + ".out.body"), written.body)
  write_text(join(directory, sheet.id + ".out.type"), written.content_type())
}

///|
/// The case as this library frames it.
fn framed(sheet : Sheet) -> @moonmime.Multipart raise @moonmime.Refused {
  match sheet.kind {
    @moonmime.FormData =>
      @moonmime.Form::new(fields=sheet.fields, files=sheet.files).encode(
        boundary?=boundary_of(sheet),
      )
    @moonmime.MultipartKind::Mixed =>
      @moonmime.Multipart::new(
        sheet.parts,
        boundary?=boundary_of(sheet),
        kind=@moonmime.MultipartKind::Mixed,
      )
  }
}

///|
/// The boundary the sheet names, or `None` when it leaves the choice to the
/// writer.
fn boundary_of(sheet : Sheet) -> StringView? {
  if sheet.boundary == "" {
    None
  } else {
    Some(sheet.boundary[:])
  }
}

///|
/// Read the case's body the way this library reads it, and write down every
/// value it found.
fn read_case(directory : String, sheet : Sheet) -> Unit {
  let body = read_bytes(join(directory, sheet.id + ".body"))
  if sheet.boundary == "" {
    return refuse("case \{sheet.id}: the sheet names no boundary")
  }
  let report = StringBuilder()
  match sheet.kind {
    @moonmime.FormData => {
      let form = @moonmime.formdata(body[:], sheet.boundary[:]) catch {
        refused => return refuse("case \{sheet.id}: \{refused.to_repr()}")
      }
      for field in form.entries() {
        report.write_string(
          "field " + cell_text(field.name) + " " + cell_text(field.value) + "\n",
        )
      }
      for upload in form.uploads() {
        report.write_string(
          "file " +
          cell_text(upload.name) +
          " " +
          cell_text(upload.filename) +
          " " +
          cell_text(upload.content_type) +
          " " +
          cell(upload.content[:]) +
          "\n",
        )
      }
    }
    @moonmime.MultipartKind::Mixed => {
      let parts = @moonmime.multipart(body[:], sheet.boundary[:]) catch {
        refused => return refuse("case \{sheet.id}: \{refused.to_repr()}")
      }
      for part in parts {
        report.write_string(
          "part " +
          cell_text(part.header("content-type").unwrap_or("")) +
          " " +
          cell(part.body[:]) +
          "\n",
        )
      }
    }
  }
  write_text(join(directory, sheet.id + ".out.read"), report.to_string())
}

// ----------------------------------------------------------------- the files

///|
/// Run `leg` over every sheet in the directory, in name order, so that two runs
/// work on the same cases in the same order.
fn for_each_sheet(directory : String, leg : (Sheet) -> Unit) -> Unit {
  let entries = @fs.read_dir(directory) catch {
    @fs.IOError(why) => return refuse("cannot list \{directory}: \{why}")
  }
  let names : Array[String] = []
  for name in entries {
    names.push(name)
  }
  names.sort()
  for name in names {
    if name.has_suffix(".sheet") {
      let id = name[0:name.length() - ".sheet".length()].to_owned()
      leg(parse_sheet(id, read_text(join(directory, name))))
    }
  }
}

///|
fn join(directory : String, name : String) -> String {
  if directory.has_suffix("/") || directory.has_suffix("\\") {
    directory + name
  } else {
    directory + "/" + name
  }
}

///|
fn read_text(path : String) -> String {
  @fs.read_file_to_string(path) catch {
    @fs.IOError(why) => refuse("cannot read \{path}: \{why}")
  }
}

///|
fn read_bytes(path : String) -> Bytes {
  @fs.read_file_to_bytes(path) catch {
    @fs.IOError(why) => refuse("cannot read \{path}: \{why}")
  }
}

///|
fn write_text(path : String, text : String) -> Unit {
  @fs.write_string_to_file(path, text) catch {
    @fs.IOError(why) => refuse("cannot write \{path}: \{why}")
  }
}

///|
fn write_bytes(path : String, bytes : Bytes) -> Unit {
  @fs.write_bytes_to_file(path, bytes) catch {
    @fs.IOError(why) => refuse("cannot write \{path}: \{why}")
  }
}

// ----------------------------------------------------------------- the sheet

///|
fn parse_sheet(id : String, text : String) -> Sheet {
  let fields : Array[@moonmime.Field] = []
  let files : Array[@moonmime.Upload] = []
  let parts : Array[@moonmime.Part] = []
  let mut kind = @moonmime.FormData
  let mut boundary = ""
  for line in lines(text) {
    let words : Array[String] = []
    for word in line.split(" ") {
      words.push(word.to_owned())
    }
    match words {
      ["kind", name] =>
        kind = match name {
          "mixed" => @moonmime.MultipartKind::Mixed
          _ => @moonmime.FormData
        }
      ["boundary", value] => boundary = decode(value)
      ["field", name, value] =>
        fields.push({ name: decode(name), value: decode(value), })
      ["file", name, filename, type_, content] =>
        files.push({
          name: decode(name),
          filename: decode(filename),
          content_type: decode(type_),
          content: decode_bytes(content),
          headers: [],
        })
      ["part", headers, body] =>
        parts.push({
          headers: parse_header_block(decode(headers)),
          body: decode_bytes(body),
        })
      [] => ()
      _ => refuse("case \{id}: cannot read the line \{line}")
    }
  }
  { id, kind, boundary, fields, files, parts, }
}

///|
/// `name: value` pairs, CRLF apart, in the order they are written.
fn parse_header_block(block : String) -> Array[(String, String)] {
  let out : Array[(String, String)] = []
  for line in lines(block) {
    let mut colon = -1
    for i = 0; i < line.length(); i = i + 1 {
      if line.at(i).to_int() == 0x3A {
        colon = i
        break
      }
    }
    if colon > 0 {
      out.push(
        (
          line[0:colon].to_lower().to_owned(),
          line[colon + 1:].trim_start().to_owned(),
        ),
      )
    }
  }
  out
}

///|
fn lines(text : String) -> Array[String] {
  let out : Array[String] = []
  let line = StringBuilder()
  for c in text {
    if c == '\n' {
      let one = line.to_string()
      out.push(without_cr(one))
      line.reset()
    } else {
      line.write_char(c)
    }
  }
  let tail = line.to_string()
  if tail != "" {
    out.push(without_cr(tail))
  }
  out
}

///|
fn without_cr(line : String) -> String {
  if line.has_suffix("\r") {
    line[0:line.length() - 1].to_owned()
  } else {
    line
  }
}

// -------------------------------------------------------------- the protocol

///|
/// One payload: base64, and `-` where there is nothing, which a space-separated
/// line can carry but an empty field cannot.
fn cell(bytes : BytesView) -> String {
  if bytes.length() == 0 {
    "-"
  } else {
    @base64.encode(bytes)
  }
}

///|
fn cell_text(text : StringView) -> String {
  cell(@utf8.encode(text)[:])
}

///|
fn decode(cell : String) -> String {
  @utf8.decode_lossy(decode_bytes(cell)[:])
}

///|
fn decode_bytes(cell : String) -> Bytes {
  if cell == "-" || cell == "" {
    b""
  } else {
    @base64.decode_lossy(cell)
  }
}
