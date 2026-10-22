// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// What a response says it is when nothing says otherwise.
pub let fallback : String = "application/octet-stream"

///|
/// The media type a filename's extension implies; `fallback` for anything else.
///
/// The last dot wins, so `archive.tar.gz` resolves on `gz`. The table is the
/// common part of the IANA registry, as Python's `mimetypes` ships it; a caller
/// that knows its type names it rather than hoping the extension does.
pub fn guess_type(filename : StringView) -> String {
  let lower = filename.to_lower()
  let mut dot = -1
  for i = 0; i < lower.length(); i = i + 1 {
    if lower[i].to_int() == 0x2E {
      dot = i
    }
  }
  if dot < 0 || dot == lower.length() - 1 {
    return fallback
  }
  let ext = lower[dot + 1:]
  for pair in types {
    if pair.0[:] == ext {
      return pair.1
    }
  }
  fallback
}

///|
/// The extension most people use for a media type, with its dot; `None` when
/// the type is not in the table. Parameters are ignored, so the value may be
/// given with its charset.
pub fn guess_extension(value : StringView) -> String? {
  let essence = media_type(value).essence
  for pair in types {
    if pair.1 == essence {
      return Some("." + pair.0)
    }
  }
  None
}

///|
/// (extension, media type), the commonest extension first for each type so
/// `guess_extension` picks it.
let types : Array[(String, String)] = [
  ("txt", "text/plain"),
  ("text", "text/plain"),
  ("log", "text/plain"),
  ("conf", "text/plain"),
  ("ini", "text/plain"),
  ("html", "text/html"),
  ("htm", "text/html"),
  ("css", "text/css"),
  ("csv", "text/csv"),
  ("md", "text/markdown"),
  ("markdown", "text/markdown"),
  ("js", "text/javascript"),
  ("mjs", "text/javascript"),
  ("json", "application/json"),
  ("xml", "application/xml"),
  ("xsl", "application/xml"),
  ("yaml", "application/yaml"),
  ("yml", "application/yaml"),
  ("toml", "application/toml"),
  ("rst", "text/x-rst"),
  ("tex", "application/x-tex"),
  ("vtt", "text/vtt"),
  ("srt", "application/x-subrip"),
  ("sql", "application/sql"),
  ("ics", "text/calendar"),
  ("rtf", "application/rtf"),
  ("sh", "text/x-shellscript"),
  ("py", "text/x-python"),
  ("png", "image/png"),
  ("apng", "image/apng"),
  ("jpg", "image/jpeg"),
  ("jpeg", "image/jpeg"),
  ("jpe", "image/jpeg"),
  ("gif", "image/gif"),
  ("webp", "image/webp"),
  ("svg", "image/svg+xml"),
  ("svgz", "image/svg+xml"),
  ("ico", "image/vnd.microsoft.icon"),
  ("bmp", "image/bmp"),
  ("tif", "image/tiff"),
  ("tiff", "image/tiff"),
  ("avif", "image/avif"),
  ("heic", "image/heif"),
  ("heif", "image/heif"),
  ("jxl", "image/jxl"),
  ("mp3", "audio/mpeg"),
  ("wav", "audio/wav"),
  ("ogg", "audio/ogg"),
  ("oga", "audio/ogg"),
  ("m4a", "audio/mp4"),
  ("aac", "audio/aac"),
  ("flac", "audio/flac"),
  ("mid", "audio/midi"),
  ("midi", "audio/midi"),
  ("opus", "audio/opus"),
  ("weba", "audio/webm"),
  ("mp4", "video/mp4"),
  ("m4v", "video/mp4"),
  ("webm", "video/webm"),
  ("mov", "video/quicktime"),
  ("avi", "video/x-msvideo"),
  ("mpeg", "video/mpeg"),
  ("mpg", "video/mpeg"),
  ("mkv", "video/x-matroska"),
  ("ogv", "video/ogg"),
  ("ts", "video/mp2t"),
  ("3gp", "video/3gpp"),
  ("woff", "font/woff"),
  ("woff2", "font/woff2"),
  ("ttf", "font/ttf"),
  ("otf", "font/otf"),
  ("eot", "application/vnd.ms-fontobject"),
  ("pdf", "application/pdf"),
  ("doc", "application/msword"),
  (
    "docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  ),
  ("xls", "application/vnd.ms-excel"),
  ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
  ("ppt", "application/vnd.ms-powerpoint"),
  (
    "pptx", "application/vnd.openxmlformats-officedocument.presentationml.presentation",
  ),
  ("odt", "application/vnd.oasis.opendocument.text"),
  ("ods", "application/vnd.oasis.opendocument.spreadsheet"),
  ("odp", "application/vnd.oasis.opendocument.presentation"),
  ("epub", "application/epub+zip"),
  ("zip", "application/zip"),
  ("gz", "application/gzip"),
  ("tgz", "application/gzip"),
  ("bz2", "application/x-bzip2"),
  ("xz", "application/x-xz"),
  ("tar", "application/x-tar"),
  ("7z", "application/x-7z-compressed"),
  ("rar", "application/vnd.rar"),
  ("zst", "application/zstd"),
  ("jar", "application/java-archive"),
  ("apk", "application/vnd.android.package-archive"),
  ("wasm", "application/wasm"),
  ("atom", "application/atom+xml"),
  ("rss", "application/rss+xml"),
  ("webmanifest", "application/manifest+json"),
  ("jsonld", "application/ld+json"),
  ("geojson", "application/geo+json"),
  ("m3u8", "application/vnd.apple.mpegurl"),
  ("plist", "application/x-plist"),
  ("pem", "application/x-x509-ca-cert"),
  ("crt", "application/x-x509-ca-cert"),
  ("der", "application/x-x509-ca-cert"),
]
