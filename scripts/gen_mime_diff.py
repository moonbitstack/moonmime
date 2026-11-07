#!/usr/bin/env python3
"""Diff moonmime's extension table against Python's `mimetypes` and Go's `mime`.

`guess_type` and `guess_extension` are decided by the table in `src/types.mbt`.
This script compares that table with the built-in tables of the two reference
implementations, so every extension the references know about is replayed and
every place the implementations disagree is written out, one line at a time, for
a decision.

Reference tables — both the library's own built-in set, not the host's:
  * Python's `mimetypes._types_map_default`, the module constant read before any
    system file. It is the table `mimetypes.guess_type` uses by default
    (`strict=True`); `_common_types_default` only applies under `strict=False`
    and is pinned alongside it for the record but not treated as a value.
  * Go's `mime.builtinTypesLower`, the small table compiled into stdlib.
    `TypeByExtension` augments it from the host's `mime.types` or the Windows
    registry, which differs per machine, so only the built-in half is compared.

Subcommands:
  refresh  re-pin the reference tables from the live libraries into
           scripts/references/ (needs `python3` and `go`).
  diff     print the full comparison to stdout.
  check    regenerate the replay test and the README divergence table in memory
           and fail when a committed file is out of date (CI; python3 only,
           reads the pinned references).
"""

import argparse
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
REF = ROOT / "scripts" / "references"
PY_REF = REF / "python_mimetypes.json"
GO_REF = REF / "go_mime.json"

TEST_OUT = ROOT / "src" / "mime_diff_test.mbt"
README = ROOT / "README.md"

BATCH = 200
TABLE_BEGIN = "<!-- mime-diff:begin -->"
TABLE_END = "<!-- mime-diff:end -->"

# The decisions: where the references disagree, or the task names the extension,
# one row per extension. The first value is the side the table takes; the string
# is why. These are the rows the README divergence table prints.
DECIDED = {
    "3gp": (
        "video/3gpp",
        "IANA registers video/3gpp for the 3GPP container; "
        "Python's audio/3gpp keeps only the audio track.",
    ),
    "heic": (
        "image/heic",
        "IANA registers image/heic for .heic, as Python does; the table's old "
        "image/heif borrowed the .heif sibling's subtype, so it is corrected to "
        "the IANA and Python side.",
    ),
    "srt": (
        "application/x-subrip",
        "neither side is IANA-registered; keeps the specific x- name "
        "over Python's generic text/plain.",
    ),
    "wav": (
        "audio/wav",
        "IANA registered audio/wav in 2018, retiring audio/x-wav; "
        "takes the IANA side over Python's x- form.",
    ),
    "xml": (
        "application/xml",
        "IANA registers application/xml (RFC 7303); the text/xml alias "
        "is retired, which Go still ships.",
    ),
    "sh": (
        "text/x-shellscript",
        "neither side is IANA-registered; keeps the semantic x- name "
        "over Python's application/x-sh.",
    ),
    "ts": (
        "video/mp2t",
        "IANA registers video/mp2t for the MPEG-2 transport stream, "
        "the common meaning of .ts; neither reference ships it.",
    ),
    "js": (
        "text/javascript",
        "all three agree and IANA registers text/javascript; "
        "Go's charset=utf-8 is a default parameter, not a different essence.",
    ),
}


def essence(type_):
    """The media type with its parameters dropped; the table stores essences."""
    return type_.split(";", 1)[0].strip().lower()


def read_moon():
    """The library's table, in order: (extension, type), commonest first."""
    text = (ROOT / "src" / "types.mbt").read_text(encoding="utf-8")
    body = text[text.index("let types"):]
    return re.findall(r'\(\s*"([^"]+)"\s*,\s*"([^"]+)"\s*,?\s*\)', body)


def read_python_live():
    import mimetypes
    std = {k.lstrip("."): v for k, v in mimetypes._types_map_default.items()}
    common = {k.lstrip("."): v for k, v in mimetypes._common_types_default.items()}
    return std, common


def read_go_live():
    goroot = subprocess.check_output(["go", "env", "GOROOT"], text=True).strip()
    src = (pathlib.Path(goroot) / "src" / "mime" / "type.go").read_text(encoding="utf-8")
    block = re.search(
        r"builtinTypesLower\s*=\s*map\[string\]string\{(.*?)\n\}", src, re.S
    ).group(1)
    return dict(re.findall(r'"\.([A-Za-z0-9]+)"\s*:\s*"([^"]+)"', block))


def read_python_pinned():
    data = json.loads(PY_REF.read_text(encoding="utf-8"))
    return data["standard"], data["common"]


def read_go_pinned():
    return json.loads(GO_REF.read_text(encoding="utf-8"))["builtin"]


def refresh_references():
    std, common = read_python_live()
    go = read_go_live()
    REF.mkdir(parents=True, exist_ok=True)
    PY_REF.write_text(
        json.dumps(
            {"python": sys.version.split()[0], "standard": std, "common": common},
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    GO_REF.write_text(
        json.dumps(
            {"go": subprocess.check_output(["go", "version"], text=True).strip(), "builtin": go},
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    print(f"pinned python ({sys.version.split()[0]}): {len(std)} standard, {len(common)} common")
    print(f"pinned go: {len(go)} built-in")


def mb_string(text):
    out = ['"']
    for ch in text:
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif 0x20 <= code <= 0x7E:
            out.append(ch)
        else:
            out.append("\\u{%04x}" % code)
    out.append('"')
    return "".join(out)


def build_rows(moon, py_std, go):
    """One row per extension in the union, with every implementation's essence."""
    moon_by_ext = {}
    for ext, type_ in moon:
        moon_by_ext.setdefault(ext, essence(type_))
    py = {ext: essence(type_) for ext, type_ in py_std.items()}
    go_by_ext = {ext: essence(type_) for ext, type_ in go.items()}
    union = sorted(set(moon_by_ext) | set(py) | set(go_by_ext))
    return [
        {
            "ext": ext,
            "moon": moon_by_ext.get(ext),
            "py": py.get(ext),
            "go": go_by_ext.get(ext),
        }
        for ext in union
    ]


def want_for(row):
    """The value the registry must return for the extension: the decided side
    where one was made, the library's own value where it has one, the fallback
    where the library deliberately leaves it out."""
    ext = row["ext"]
    if ext in DECIDED:
        return DECIDED[ext][0]
    return row["moon"] if row["moon"] is not None else "application/octet-stream"


def case_lines(ext, want):
    """One case as the formatter lays it out: on one line while it fits in the
    margin, split over three when it does not, with both strings kept together
    on the middle line. Emitting the wrapped form here is what keeps `moon fmt`
    from rewriting the generated file (same rule as gen_wpt_vectors.py)."""
    one = f"    ({mb_string(ext)}, {mb_string(want)}),"
    if len(one) <= 81:
        return [one]
    return [
        "    (",
        f"      {mb_string(ext)}, {mb_string(want)},",
        "    ),",
    ]


def render_test(rows):
    header = (
        "// Copyright 2026 Leo Cheng\n"
        "// SPDX-License-Identifier: Apache-2.0\n"
        "\n"
        "// Generated by scripts/gen_mime_diff.py from the pinned reference\n"
        "// tables under scripts/references/ and the table in src/types.mbt.\n"
        "// Every extension the references know about is replayed against\n"
        "// guess_type: the decided value where the references disagree, the\n"
        "// library's value where it has one, the fallback where it does not.\n"
        "// Do not edit: change src/types.mbt and run the generator, which\n"
        "// keeps this file and the divergence table in step.\n"
    )
    cases = [("." + r["ext"], want_for(r)) for r in rows]
    out = [header.rstrip("\n")]
    batches = [cases[i : i + BATCH] for i in range(0, len(cases), BATCH)]
    for n, batch in enumerate(batches, start=1):
        out.append("")
        out.append("///|")
        out.append(f"fn mime_diff_{n}() -> Array[(String, String)] {{")
        out.append("  [")
        for ext, want in batch:
            out.extend(case_lines(ext, want))
        out.append("  ]")
        out.append("}")
    out.append("")
    out.append("///|")
    out.append("fn mime_diff_cases() -> Array[(String, String)] {")
    out.append("  let out : Array[(String, String)] = []")
    for n in range(1, len(batches) + 1):
        out.append(f"  out.append(mime_diff_{n}()[:])")
    out.append("  out")
    out.append("}")
    out.append("")
    out.append("///|")
    out.append('/// Replay the references\' full extension list against the registry.')
    out.append('test "the references\' extensions all replay" {')
    out.append("  for pair in mime_diff_cases() {")
    out.append('    assert_eq(@moonmime.guess_type(pair.0[:]), pair.1)')
    out.append("  }")
    out.append("}")
    return "\n".join(out) + "\n"


def md_cell(value):
    return value if value else "—"


def render_table():
    """The whole managed block: the section heading, the prose, and the table,
    between the begin and end markers so the generator owns it end to end."""
    lines = [
        TABLE_BEGIN,
        "### The extension table",
        "",
        "`guess_type` and `guess_extension` are decided by a table of the common",
        "extensions, the part the implementations most often disagree on. It was",
        "differed against Python's `mimetypes` and Go's `mime`; every extension the",
        "references know about is replayed by a test, and where the references",
        "disagree the table takes a side: IANA where it registers one, the more",
        "specific name where it does not. The task also named `.ts` and `.js`, so",
        "they are decided here too — one line each:",
        "",
        "| Extension | moonmime | Python `mimetypes` | Go `mime` | Why |",
        "| --- | --- | --- | --- | --- |",
    ]
    for ext, (side, why) in DECIDED.items():
        py = GO = "—"
        for r in _rows_cache:
            if r["ext"] == ext:
                py = r["py"] if r["py"] else "—"
                GO = r["go"] if r["go"] else "—"
        lines.append(f"| `.{ext}` | {side} | {py} | {GO} | {why} |")
    lines.append("")
    lines.append(
        "The rest of the union the library has no entry for — it answers "
        "`application/octet-stream` for them, which is what `guess_type` promises"
    )
    lines.append("for a name it has not heard.")
    lines.append(TABLE_END)
    return "\n".join(lines)


_rows_cache = []


def main(argv):
    global _rows_cache
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "command", choices=["refresh", "diff", "gen", "check"], nargs="?", default="check"
    )
    args = ap.parse_args(argv)

    if args.command == "refresh":
        refresh_references()
        return 0

    if PY_REF.exists() and GO_REF.exists():
        py_std, _common = read_python_pinned()
        go = read_go_pinned()
    else:
        py_std, _common = read_python_live()
        go = read_go_live()

    moon = read_moon()
    rows = build_rows(moon, py_std, go)
    _rows_cache = rows
    decided = set(DECIDED)

    if args.command == "diff":
        print(
            f"library: {len(moon)} | python(std): {len(py_std)} | go(builtin): {len(go)} "
            f"| union: {len(rows)} | decided: {len(decided)}"
        )
        print()
        print("decided rows (the README divergence table):")
        for r in rows:
            if r["ext"] in decided:
                print(
                    f"  .{r['ext']:<7} moon={r['moon'] or '-':<14} "
                    f"py={r['py'] or '-':<22} go={r['go'] or '-'}"
                )
        print()
        print("all extensions the references know that the library falls back on:")
        for r in rows:
            if r["moon"] is None:
                print(f"  .{r['ext']:<10} py={r['py'] or '-':<22} go={r['go'] or '-'}")
        return 0

    test_text = render_test(rows)
    table_text = render_table()
    print(f"replay: {len(rows)} extensions | decided: {len(decided)}")

    if args.command == "gen":
        with open(TEST_OUT, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(test_text)
        print(f"wrote {TEST_OUT.relative_to(ROOT)}: {len(rows)} cases")
        readme = README.read_text(encoding="utf-8")
        m = re.search(
            re.escape(TABLE_BEGIN) + r".*?" + re.escape(TABLE_END), readme, re.S
        )
        if m:
            readme = readme[: m.start()] + table_text + readme[m.end() :]
        else:
            # No table yet: it is the second subject of Conformance, so it sits
            # at the end of that section, before the licence heading.
            anchor = "## Licence"
            if anchor in readme:
                readme = readme[: readme.index(anchor)] + table_text + "\n\n" + readme[
                    readme.index(anchor) :
                ]
        with open(README, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(readme)
        print(f"wrote {README.relative_to(ROOT)} (divergence table)")
        return 0

    # check: compare the committed files against what the generator would write.
    stale = []
    current_test = TEST_OUT.read_text(encoding="utf-8") if TEST_OUT.exists() else ""
    if current_test != test_text:
        stale.append("src/mime_diff_test.mbt")
    readme = README.read_text(encoding="utf-8")
    m = re.search(re.escape(TABLE_BEGIN) + r".*?" + re.escape(TABLE_END), readme, re.S)
    if not m or m.group(0) != table_text:
        stale.append("README.md (divergence table)")
    if stale:
        print("out of date: " + ", ".join(stale), file=sys.stderr)
        print("run scripts/gen_mime_diff.py", file=sys.stderr)
        return 1
    print("the replay test and the divergence table are current")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
