// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A named text value from a form.
pub(all) struct Field {
  name : String
  value : String
} derive(Eq, Debug)

///|
pub extend Field with Eq::{equal, not_equal}

///|
pub extend Field with Debug::{to_repr}

///|
/// A file from a `multipart/form-data` body.
///
/// The content is held whole. Streaming a part to disk instead of into memory
/// is what `limits` exists to make unnecessary until it is built.
pub(all) struct Upload {
  name : String
  filename : String
  content_type : String
  content : Bytes
  headers : Array[(String, String)]
} derive(Eq, Debug)

///|
pub extend Upload with Eq::{equal, not_equal}

///|
pub extend Upload with Debug::{to_repr}

///|
/// The size of the uploaded content in bytes.
pub fn Upload::size(self : Upload) -> Int32 {
  self.content.length()
}

///|
/// One of the part's own headers, by lowercased name.
pub fn Upload::header(self : Upload, name : StringView) -> String? {
  header_of(self.headers, name)
}

///|
/// A parsed form: its text fields and its files.
struct Form {
  fields : Array[Field]
  files : Array[Upload]
}

///|
/// The first value under this name.
pub fn Form::field(self : Form, name : StringView) -> String? {
  for field in self.fields {
    if field.name[:] == name {
      return Some(field.value)
    }
  }
  None
}

///|
/// Every value under this name — a set of checkboxes sends the same name many
/// times, and taking only the first silently drops the rest.
pub fn Form::values(self : Form, name : StringView) -> Array[String] {
  let out : Array[String] = []
  for field in self.fields {
    if field.name[:] == name {
      out.push(field.value)
    }
  }
  out
}

///|
/// The first file under this name.
pub fn Form::file(self : Form, name : StringView) -> Upload? {
  for upload in self.files {
    if upload.name[:] == name {
      return Some(upload)
    }
  }
  None
}

///|
/// Every field, in the order they were sent.
pub fn Form::entries(self : Form) -> Array[Field] {
  self.fields
}

///|
/// Every file, in the order they were sent.
pub fn Form::uploads(self : Form) -> Array[Upload] {
  self.files
}

///|
/// Whether anything was parsed at all.
pub fn Form::is_empty(self : Form) -> Bool {
  self.fields.length() == 0 && self.files.length() == 0
}

///|
/// Parse a body by what its `Content-Type` says it is.
///
/// A content type that is not `multipart/form-data` yields an empty form rather
/// than an error: "this request carried no form" is an answer, not a failure.
/// `strict` is for the caller who would rather be told.
pub fn form(
  body : BytesView,
  content_type : StringView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> Form raise Refused {
  let mt = media_type(content_type)
  if mt.essence == "multipart/form-data" {
    match mt.param("boundary") {
      Some(edge) => formdata(body, edge[:], limits~, strict~)
      None =>
        if strict {
          raise NotAForm(content_type=content_type.to_owned())
        } else {
          { fields: [], files: [], }
        }
    }
  } else if strict {
    raise NotAForm(content_type=content_type.to_owned())
  } else {
    { fields: [], files: [], }
  }
}

///|
/// Parse a `multipart/form-data` body (RFC 7578) given its boundary.
///
/// A part goes into the files when its `Content-Disposition` carries a
/// `filename` and into the fields when it does not, which is the only thing
/// distinguishing them on the wire.
pub fn formdata(
  body : BytesView,
  boundary : StringView,
  limits~ : Limits = limits,
  strict~ : Bool = false,
) -> Form raise Refused {
  let fields : Array[Field] = []
  let files : Array[Upload] = []
  for part in multipart(body, boundary, limits~, strict~) {
    let disposition = part.disposition()
    let name = match disposition {
      Some(d) => d.param("name").unwrap_or("")
      None => ""
    }
    match disposition {
      Some(d) =>
        match d.filename() {
          Some(filename) =>
            files.push({
              name,
              filename,
              content_type: part.header("content-type").unwrap_or(""),
              content: part.body,
              headers: part.headers,
            })
          None => fields.push({ name, value: text(part.body[:]), })
        }
      None => fields.push({ name, value: text(part.body[:]), })
    }
  }
  { fields, files, }
}
