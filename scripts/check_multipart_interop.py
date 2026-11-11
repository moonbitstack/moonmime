#!/usr/bin/env python3
"""Bidirectional interop for multipart bodies, with Python and Go.

Every case in `scripts/interop/cases.json` goes through each implementation in
both roles. Each one writes the body for the case — its own boundary, its own
header folding, its own line endings — and then every implementation reads that
body back, the writer among them, and what it read is compared with what the
case says went in. So a disagreement is always between two readers over the same
octets, never between a reader and its own writer.

The three implementations:

* **this library**, through `integration/interop`, the exchange program in
  `src/main` that frames a sheet with `Form::encode` or `Multipart::new` and
  reads one with `formdata` or `multipart`;
* **Python's `email`** — `EmailMessage` and its generator write the body, and
  `message_from_bytes` plus `get_filename` read it back. Its generator folds a
  long `Content-Disposition` across lines, which is why this library unfolds;
* **Go's `mime/multipart`** — the `Writer` and `Reader` every Go server reads
  uploads with, and what a Go client would hand a form to.

An exchange is a directory of sheets: `write <dir>` turns every `<id>.sheet`
into `<id>.out.body` and `<id>.out.type`, `read <dir>` turns `<id>.body` and its
sheet into `<id>.out.read`. A sheet is one case, one clause a line, and every
payload base64 so that a space separates the fields of a line and nothing else
can:

    kind form-data | mixed | related
    boundary <value>                    (absent: the writer chooses one)
    related <type> <start> <start-info>  (related only; absent: no parameters)
    header <content-type>               (read only: the header the body came with)
    field <name> <value>
    file <name> <filename> <content-type> <content>
    part <headers> <body>               headers are "name: value", CRLF apart

and a report is one line per value read, in the same notation.

    python3 scripts/check_multipart_interop.py [--keep]

Needs `moon` and `go` on the path.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import email.message
import email.utils
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "scripts" / "interop" / "cases.json"
EXCHANGE = ROOT / "integration" / "interop"
GO = ROOT / "scripts" / "interop" / "go"


# --------------------------------------------------------------- the notation


def cell(data: bytes) -> str:
    """One payload: base64, and `-` where there is nothing."""
    return "-" if not data else base64.b64encode(data).decode("ascii")


def uncell(word: str) -> bytes:
    return b"" if word in ("-", "") else base64.b64decode(word)


def content(entry: dict) -> bytes:
    """A case's payload: text as it stands, or the bytes it spells."""
    if "content_b64" in entry:
        return base64.b64decode(entry["content_b64"])
    return entry.get("content", "").encode("utf-8")


def headers_of(part: dict) -> str:
    block = ""
    if part.get("content_type"):
        block += f"content-type: {part['content_type']}\r\n"
    if part.get("content_id"):
        block += f"content-id: {part['content_id']}\r\n"
    return block


def sheet_text(case: dict, boundary: str | None, header: str | None = None) -> str:
    lines = [f"kind {case['kind']}"]
    if boundary is not None:
        lines.append(f"boundary {cell(boundary.encode('utf-8'))}")
    related = case.get("related")
    if related:
        lines.append(
            "related "
            + " ".join(
                cell(related.get(key, "").encode("utf-8"))
                for key in ("type", "start", "start_info")
            )
        )
    if header is not None:
        lines.append(f"header {cell(header.encode('utf-8'))}")
    for name, value in case.get("fields", []):
        lines.append(f"field {cell(name.encode('utf-8'))} {cell(value.encode('utf-8'))}")
    for one in case.get("files", []):
        lines.append(
            "file "
            + " ".join(
                [
                    cell(one["name"].encode("utf-8")),
                    cell(one["filename"].encode("utf-8")),
                    cell(one.get("content_type", "").encode("utf-8")),
                    cell(content(one)),
                ]
            )
        )
    for one in case.get("parts", []):
        lines.append(f"part {cell(headers_of(one).encode('utf-8'))} {cell(content(one))}")
    return "\n".join(lines) + "\n"


def expected(case: dict, writer: str | None = None) -> list[str]:
    """What a reader has to find in a body of this case, in report notation.

    A case whose `diverges` names this writer carries the lines the divergence
    costs: the check looks for them, so a claim that two implementations frame
    a body differently cannot quietly stop being true.
    """
    if case["kind"] == "form-data":
        out = [
            f"field {cell(name.encode('utf-8'))} {cell(value.encode('utf-8'))}"
            for name, value in case.get("fields", [])
        ]
        out += [
            "file "
            + " ".join(
                [
                    cell(one["name"].encode("utf-8")),
                    cell(one["filename"].encode("utf-8")),
                    cell(one.get("content_type", "").encode("utf-8")),
                    cell(content(one)),
                ]
            )
            for one in case.get("files", [])
        ]
        return out
    parts = [
        f"part {cell(one.get('content_type', '').encode('utf-8'))} {cell(content(one))}"
        for one in case.get("parts", [])
    ]
    if case["kind"] != "related":
        return parts
    related = case.get("related", {})
    out = [
        "related "
        + " ".join(
            cell(related.get(key, "").encode("utf-8"))
            for key in ("type", "start", "start_info")
        )
    ]
    out += parts
    root = root_part(case)
    if root is None:
        out.append("root - -")
    else:
        out.append(
            f"root {cell(root.get('content_type', '').encode('utf-8'))} {cell(content(root))}"
        )
    return out


def stripped(content_id: str) -> str:
    """A content ID as it is compared: the address inside the angle brackets."""
    text = content_id.strip()
    if len(text) >= 2 and text[0] == "<" and text[-1] == ">":
        return text[1:-1]
    return text


def root_part(case: dict):
    """The part the header names as the root, or the first one when it names
    none — RFC 2387's default. `None` when it names a part the body lacks."""
    parts = case.get("parts", [])
    start = case.get("related", {}).get("start", "")
    if not start:
        return parts[0] if parts else None
    for one in parts:
        if stripped(one.get("content_id", "")) == stripped(start):
            return one
    return None


def expected_of(case: dict, writer: str) -> list[str]:
    lines = expected(case)
    diverges = case.get("diverges")
    if diverges and diverges["writer"] == writer:
        lines = lines + diverges["reports"]
    return lines


def quoted(boundary: str) -> str:
    return boundary.replace("\\", "\\\\").replace('"', '\\"')


def related_header(case: dict, boundary: str) -> str:
    """`multipart/related` and the parameters RFC 2387 defines, in its order."""
    header = f'multipart/related; boundary="{quoted(boundary)}"'
    for key in ("type", "start", "start_info"):
        value = case.get("related", {}).get(key, "")
        if value:
            name = "start-info" if key == "start_info" else key
            header += f'; {name}="{quoted(value)}"'
    return header


TOKEN = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")


def well_formed(content_type: str, boundary: str) -> bool:
    """Whether the header keeps the boundary in one piece.

    RFC 2045 §5.1 lets a parameter value go bare only when it is a token; a
    boundary with a space in it has to be quoted, or a reader that stops at the
    space gets a boundary of its own invention. `email` is forgiving enough to
    read either, which is why this is checked here rather than left to it.
    """
    if TOKEN.match(boundary):
        # Either form reads back the same; only the shape that cannot be read
        # back bare is worth insisting on.
        return True
    return f'boundary="{quoted(boundary)}"' in content_type


def boundary_of(content_type: str) -> str:
    """The boundary a `Content-Type` names, read by Python's own parser.

    Reading it back with a second implementation is also how the header's
    quoting gets checked: a boundary with a space only comes back whole because
    the value went out quoted.
    """
    message = email.message.Message()
    message["Content-Type"] = content_type
    boundary = message.get_param("boundary")
    if boundary is None:
        raise SystemExit(f"no boundary in the header {content_type!r}")
    return boundary


# ------------------------------------------------------------ the three sides


def run(command: list[str], cwd: Path) -> None:
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True)
    if result.returncode != 0:
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit(f"{' '.join(command)} failed in {cwd}")


def sheets(directory: Path) -> list[Path]:
    return sorted(directory.glob("*.sheet"))


def moon(mode: str, directory: Path, plans: dict) -> None:
    run(
        ["moon", "run", "src/main", "--target", "native", "--", mode, str(directory)],
        EXCHANGE,
    )


def go(mode: str, directory: Path, plans: dict) -> None:
    run(["go", "run", "main.go", mode, str(directory)], GO)


def python_write(directory: Path, plans: dict[str, tuple[dict, str]]) -> None:
    """Write every case with Python's `email`, as a mail client would.

    The payload of a part goes in as bytes, with no transfer encoding: RFC 7578
    form data is 8-bit and a browser sends it that way.
    """
    import email.policy
    from email.generator import BytesGenerator
    import io

    for path in sheets(directory):
        case_id = path.stem
        case, boundary = plans[case_id]
        message = email.message.EmailMessage(policy=email.policy.SMTP)
        message["MIME-Version"] = "1.0"
        if case["kind"] == "related":
            message["Content-Type"] = related_header(case, boundary)
        else:
            message["Content-Type"] = f'multipart/{case["kind"]}; boundary="{quoted(boundary)}"'
        for name, value in case.get("fields", []):
            part = email.message.EmailMessage(policy=email.policy.SMTP)
            part["Content-Disposition"] = f'form-data; name="{quoted_name(name)}"'
            part.set_payload(value.encode("utf-8"))
            message.attach(part)
        for one in case.get("files", []):
            part = email.message.EmailMessage(policy=email.policy.SMTP)
            part["Content-Disposition"] = (
                f'form-data; name="{quoted_name(one["name"])}"; '
                + filename_param(one["filename"])
            )
            if one.get("content_type"):
                part["Content-Type"] = one["content_type"]
            part.set_payload(content(one))
            message.attach(part)
        for one in case.get("parts", []):
            part = email.message.EmailMessage(policy=email.policy.SMTP)
            if one.get("content_type"):
                part["Content-Type"] = one["content_type"]
            if one.get("content_id"):
                part["Content-ID"] = one["content_id"]
            part.set_payload(content(one))
            message.attach(part)
        buffer = io.BytesIO()
        BytesGenerator(buffer, mangle_from_=False, maxheaderlen=76).flatten(message)
        raw = buffer.getvalue()
        body = raw.split(b"\r\n\r\n", 1)[1]
        (directory / f"{case_id}.out.body").write_bytes(body)
        # A folded header is one value: the sheet that carries it to another
        # reader has to hold it on one line, and the value is the same either
        # way.
        header = str(message["Content-Type"]).replace("\r\n ", " ").replace("\n ", " ")
        (directory / f"{case_id}.out.type").write_text(header, encoding="utf-8")


def quoted_name(name: str) -> str:
    return name.replace("\\", "\\\\").replace('"', '\\"')


def filename_param(filename: str) -> str:
    """`filename="..."`, or the extended form when the name leaves ASCII."""
    try:
        filename.encode("ascii")
    except UnicodeEncodeError:
        pass
    else:
        if all(0x20 <= ord(c) <= 0x7E and c not in '"\\' for c in filename):
            return f'filename="{filename}"'
    return "filename*=utf-8''" + percent_encode(filename)


def percent_encode(text: str) -> str:
    out = []
    for byte in text.encode("utf-8"):
        c = chr(byte)
        if c.isascii() and (c.isalnum() or c in "-._~"):
            out.append(c)
        else:
            out.append(f"%{byte:02X}")
    return "".join(out)


def python(mode: str, directory: Path, plans: dict[str, tuple[dict, str]]) -> None:
    if mode == "write":
        python_write(directory, plans)
    else:
        python_read(directory, plans)


def python_read(directory: Path, plans: dict[str, tuple[dict, str, str]]) -> None:
    """Read every body with Python's `email`, and write down what it found."""
    for path in sheets(directory):
        case_id = path.stem
        case, boundary, header = plans[case_id]
        body = (directory / f"{case_id}.body").read_bytes()
        raw = (
            "MIME-Version: 1.0\r\n"
            f"Content-Type: {header}\r\n"
            "\r\n"
        ).encode("utf-8") + body
        message = email.message_from_bytes(raw, policy=email.policy.default)
        lines: list[str] = []
        if case["kind"] == "related":
            lines.append(
                "related "
                + " ".join(
                    cell(param_bytes(message, key))
                    for key in ("type", "start", "start-info")
                )
            )
        parts = message.get_payload()
        if isinstance(parts, str):
            # A body with no parts at all leaves nothing to walk.
            parts = []
        for part in parts:
            if case["kind"] == "form-data":
                name = header_bytes(part.get_param("name", header="content-disposition"))
                filename = part.get_filename()
                payload = part.get_payload(decode=True) or b""
                if filename is not None:
                    lines.append(
                        "file "
                        + " ".join(
                            [
                                cell(name),
                                cell(header_bytes(filename)),
                                cell(header_bytes(part.get("Content-Type"))),
                                cell(payload),
                            ]
                        )
                    )
                else:
                    lines.append(f"field {cell(name)} {cell(payload)}")
            else:
                lines.append(
                    "part "
                    + cell(header_bytes(part.get("Content-Type")))
                    + " "
                    + cell(part.get_payload(decode=True) or b"")
                )
        if case["kind"] == "related":
            root = root_part(case)
            found = None
            start = stripped(case.get("related", {}).get("start", ""))
            for part in parts:
                content_id = header_bytes(part.get("Content-ID")).decode("utf-8", "surrogateescape")
                if not start and found is None:
                    found = part
                elif start and stripped(content_id) == start:
                    found = part
            if found is None:
                lines.append("root - -")
            else:
                lines.append(
                    "root "
                    + cell(header_bytes(found.get("Content-Type")))
                    + " "
                    + cell(found.get_payload(decode=True) or b"")
                )
            del root
        (directory / f"{case_id}.out.read").write_text(
            "\n".join(lines) + ("\n" if lines else ""), encoding="utf-8"
        )


def param_bytes(message, key: str) -> bytes:
    """A parameter of the header, as the bytes the sender wrote."""
    value = message.get_param(key)
    return b"" if value is None else header_bytes(value)


def header_bytes(value) -> bytes:
    """A header value back as the bytes the sender wrote.

    compat32 keeps bytes above ASCII as surrogate escapes rather than decoding
    them, which is what a raw UTF-8 parameter is on the wire; encoding them back
    is how those bytes are recovered.
    """
    if value is None:
        return b""
    if isinstance(value, tuple):
        value = email.utils.collapse_rfc2231_value(value)
    return str(value).encode("utf-8", "surrogateescape")


# ------------------------------------------------------------------ the check


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--keep", action="store_true", help="leave the exchanged bodies in place")
    options = parser.parse_args()

    cases = json.loads(CORPUS.read_text(encoding="utf-8"))
    work = Path(tempfile.mkdtemp(prefix="moonmime-interop-"))
    wrong: list[str] = []
    passes = 0
    part_at_a_time = 0
    try:
        written: dict[str, Path] = {}
        for name in IMPLS:
            directory = work / f"written-by-{name}"
            directory.mkdir()
            plans = {}
            for case in cases:
                boundary = case.get("boundary")
                plans[case["id"]] = (case, boundary or CHOSEN[name])
                (directory / f"{case['id']}.sheet").write_text(
                    sheet_text(case, boundary), encoding="utf-8"
                )
            IMPLS[name]("write", directory, plans)
            written[name] = directory

        # A body written a part at a time has to be the body written in one
        # call, octet for octet. Only this library writes the second one; where
        # it is there, the two are compared.
        for name, directory in written.items():
            for case in cases:
                streamed = directory / f"{case['id']}.out.stream"
                if not streamed.exists():
                    continue
                one_shot = (directory / f"{case['id']}.out.body").read_bytes()
                part_at_a_time += 1
                if streamed.read_bytes() != one_shot:
                    wrong.append(
                        f"{name} wrote {case['id']} a part at a time as other octets "
                        f"than in one call"
                    )

        for name, directory in written.items():
            for case in cases:
                case_id = case["id"]
                header = (directory / f"{case_id}.out.type").read_text(encoding="utf-8")
                if not header.startswith(f"multipart/{case['kind']};"):
                    wrong.append(f"{name} wrote {case_id} as {header!r}")
                    continue
                boundary = boundary_of(header)
                if not well_formed(header, boundary):
                    wrong.append(f"{name} wrote {case_id} as {header!r}, which does not hold the boundary in one piece")
                if case.get("boundary") and boundary != case["boundary"]:
                    wrong.append(
                        f"{name} wrote {case_id} with the boundary {boundary!r}, "
                        f"not {case['boundary']!r}"
                    )

        for writer in written:
            source = written[writer]
            for reader in IMPLS:
                directory = work / f"{writer}-read-by-{reader}"
                directory.mkdir()
                plans = {}
                for case in cases:
                    case_id = case["id"]
                    header = (source / f"{case_id}.out.type").read_text(encoding="utf-8")
                    boundary = boundary_of(header)
                    plans[case_id] = (case, boundary, header)
                    (directory / f"{case_id}.sheet").write_text(
                        sheet_text(case, boundary, header), encoding="utf-8"
                    )
                    shutil.copyfile(source / f"{case_id}.out.body", directory / f"{case_id}.body")
                IMPLS[reader]("read", directory, plans)
                passes += 1
                for case in cases:
                    case_id = case["id"]
                    report = directory / f"{case_id}.out.read"
                    if not report.exists():
                        wrong.append(f"{reader} read nothing of {writer}'s {case_id}")
                        continue
                    found = report.read_text(encoding="utf-8").splitlines()
                    want = expected_of(case, writer)
                    for line in sorted(set(want) - set(found)):
                        wrong.append(f"{reader} lost {line!r} of {writer}'s {case_id}")
                    for line in sorted(set(found) - set(want)):
                        wrong.append(f"{reader} invented {line!r} in {writer}'s {case_id}")

        for line in wrong:
            print("  " + line)
        if wrong:
            print(f"{len(wrong)} disagreements")
            return 1
        print(
            f"interop: {len(cases)} cases, {len(IMPLS)} implementations, "
            f"{passes} reader passes, {part_at_a_time} bodies written a part at a time, "
            "both directions"
        )
        return 0
    finally:
        if options.keep:
            print(f"exchanges kept in {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


IMPLS = {"moon": moon, "python": python, "go": go}

# What each writer falls back to when a case leaves the boundary to it.
CHOSEN = {"moon": "----moonmime", "python": "----python", "go": "chosen by the writer"}


if __name__ == "__main__":
    raise SystemExit(main())
