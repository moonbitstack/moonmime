#!/usr/bin/env python3
# Generate docs/api.html from pkg.generated.mbti and the /// comments in source.
# Deterministic: no timestamps, sorted order, LF endings. CI re-runs this and
# asserts `git diff --exit-code docs/api.html` is empty.
import html
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
MBTI = ROOT / "pkg.generated.mbti"
SOURCES = [ROOT / n for n in [
    "media.mbt", "disposition.mbt", "multipart.mbt", "formdata.mbt", "types.mbt",
]]
OUT = ROOT / "docs" / "api.html"

# Methods a derive produces; they are not the public surface to document.
DERIVED = {"equal", "not_equal", "to_repr", "output", "compare", "hash"}


# ------------------------------------------------------------------ comments
def parse_comments():
    desc = {}
    variants = {}
    for path in SOURCES:
        if not path.exists():
            continue
        buf = []
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.rstrip()
            stripped = line.strip()
            if stripped.startswith("///"):
                buf.append(re.sub(r"^\s*///\|?\s?", "", line))
                continue
            if not stripped:
                continue
            key = None
            m = re.match(r"pub fn (\w+)::(\w+)", stripped)
            if m:
                key = f"{m.group(1)}::{m.group(2)}"
            else:
                m = re.match(r"pub fn (\w+)\s*\(", stripped)
                if m:
                    key = m.group(1)
                else:
                    m = re.match(r"pub let (\w+)\s*:", stripped)
                    if m:
                        key = m.group(1)
                    else:
                        m = re.match(r"pub\(all\)\s+struct\s+(\w+)", stripped)
                        if m:
                            key = m.group(1)
                        else:
                            m = re.match(r"pub\(all\)\s+suberror\s+(\w+)", stripped)
                            if m:
                                key = m.group(1)
                            else:
                                m = re.match(r"type\s+(\w+)\s*$", stripped)
                                if m:
                                    key = m.group(1)
                                else:
                                    m = re.match(
                                        r"pub impl Show for (\w+)\s+with\s+fn\s+to_string",
                                        stripped,
                                    )
                                    if m:
                                        key = f"{m.group(1)}::to_string"
            vm = re.match(r"^([A-Z][A-Za-z0-9]*)\(.*\)\s*$", stripped)
            if vm and buf:
                variants[vm.group(1)] = "\n".join(buf).strip()
            if key and buf:
                desc[key] = "\n".join(buf).strip()
            buf = []
    return desc, variants


# ------------------------------------------------------------------ mbti
def parse_mbti():
    values = []
    types = []
    cur = None
    in_block = False
    for raw in MBTI.read_text(encoding="utf-8").splitlines():
        s = raw.strip()
        if in_block:
            if s.startswith("}") or s.startswith("derive"):
                in_block = False
                continue
            if s:
                cur["members"].append(s)
            continue
        if not s or s.startswith("//"):
            continue
        m = re.match(r"pub\(all\)\s+struct\s+(\w+)\s*\{", s)
        if m:
            cur = {"kind": "struct", "name": m.group(1), "members": [], "methods": []}
            types.append(cur)
            in_block = True
            continue
        m = re.match(r"pub\(all\)\s+suberror\s+(\w+)\s*\{", s)
        if m:
            cur = {"kind": "suberror", "name": m.group(1), "members": [], "methods": []}
            types.append(cur)
            in_block = True
            continue
        m = re.match(r"type\s+(\w+)\s*$", s)
        if m:
            cur = {"kind": "type", "name": m.group(1), "members": [], "methods": []}
            types.append(cur)
            continue
        m = re.match(r"pub fn (\w+)::(\w+)\((.*)$", s)
        if m:
            owner = next((t for t in types if t["name"] == m.group(1)), None)
            if owner is not None:
                owner["methods"].append({"name": m.group(2), "sig": s})
            continue
        m = re.match(r"pub fn (\w+)\((.*)$", s)
        if m:
            values.append({"kind": "fn", "name": m.group(1), "sig": s})
            continue
        m = re.match(r"pub let (\w+)\s*:", s)
        if m:
            values.append({"kind": "let", "name": m.group(1), "sig": s})
            continue
    for t in types:
        t["methods"] = sorted(
            [m for m in t["methods"] if m["name"] not in DERIVED],
            key=lambda m: m["name"],
        )
    return sorted(values, key=lambda v: v["name"]), types


# ------------------------------------------------------------------ render
def render_desc(text):
    if not text:
        return ""
    text = html.escape(text)
    chunks = re.split(r"\n\s*\n", text.strip())
    out = []
    for c in chunks:
        c = re.sub(r"\s*\n\s*", " ", c)
        c = re.sub(r"`([^`]+)`", r"<code>\1</code>", c)
        out.append(f'<p class="api-desc">{c}</p>')
    return "\n".join(out)


def sig_html(sig, name=None):
    s = html.escape(sig)
    s = s.replace("-&gt;", '<span class="kw">-&gt;</span>')
    if name:
        target = html.escape(name)
        s = s.replace(target, f'<span class="fn">{target}</span>', 1)
    s = re.sub(r"^(pub fn|pub let|pub\(all\) struct|pub\(all\) suberror|type)\b",
               r'<span class="kw">\1</span>', s)
    return s


EXAMPLES = {
    "media_type": (
        'let mt = @moonmime.media_type("text/plain; charset=utf-8")\n'
        'println(mt.essence)                    // text/plain\n'
        'println(mt.param("charset").unwrap_or(""))  // utf-8',
        "text/plain\nutf-8",
    ),
    "content_disposition": (
        'println(@moonmime.content_disposition("menu.pdf"))\n'
        'println(@moonmime.content_disposition("receta \\"de la abuela\\".pdf"))',
        'attachment; filename="menu.pdf"\n'
        "attachment; filename*=utf-8''receta%20%22de%20la%20abuela%22.pdf",
    ),
    "multipart": (
        'let parts = @moonmime.multipart(body, "b")\n'
        'println(parts.length())                       // 1\n'
        'println(parts[0].header("content-type").unwrap_or(""))  // text/plain',
        "1\ntext/plain",
    ),
    "formdata": (
        'let form = @moonmime.formdata(body, "----edge")\n'
        'println(form.field("recipe").unwrap_or(""))  // chiles en nogada',
        "chiles en nogada",
    ),
    "Disposition::parse": (
        'let d = @moonmime.Disposition::parse(\n'
        '  "attachment; filename=\\"fallback.txt\\"; filename*=utf-8\'\'r%C3%A9sum%C3%A9.txt",\n'
        ")\n"
        'println(d.filename().unwrap_or(""))  // résumé.txt',
        "résumé.txt",
    ),
    "guess_type": (
        'println(@moonmime.guess_type("factura.PDF"))        // application/pdf\n'
        'println(@moonmime.guess_type("archive.tar.gz"))     // application/gzip',
        "application/pdf\napplication/gzip",
    ),
}


def example_html(name):
    if name not in EXAMPLES:
        return ""
    code, out = EXAMPLES[name]
    return (
        '<div class="codeblock">'
        '<div class="codeblock__bar"><span>example</span></div>'
        f"<pre><code>{html.escape(code)}</code></pre>"
        f'<div class="out">{html.escape(out)}</div>'
        "</div>"
    )


def api_item(anchor, sig, desc_key, desc_map, name=None):
    return (
        f'<div class="api-item" id="{anchor}">'
        f'<div class="api-sig">{sig_html(sig, name)}</div>'
        f"{render_desc(desc_map.get(desc_key, ''))}"
        f"{example_html(desc_key)}"
        "</div>"
    )


def build():
    desc, variants = parse_comments()
    values, types = parse_mbti()

    errors = sorted([t for t in types if t["kind"] == "suberror"], key=lambda t: t["name"])
    structs = sorted([t for t in types if t["kind"] != "suberror"], key=lambda t: t["name"])

    body = []
    toc = []

    # ---- values ----
    body.append('<div class="api-group"><h2 id="values">Values</h2>')
    toc.append(('<div class="toc__h">Values</div>', ''))
    for v in values:
        anchor = "v-" + v["name"]
        toc.append((f'<a href="#{anchor}">{v["name"]}</a>', ""))
        body.append(api_item(anchor, v["sig"], v["name"], desc, v["name"]))
    body.append("</div>")

    # ---- types ----
    body.append('<div class="api-group"><h2 id="types">Types</h2>')
    toc.append(('<div class="toc__h">Types</div>', ""))
    for t in structs:
        anchor = "t-" + t["name"]
        toc.append((f'<a href="#{anchor}">{t["name"]}</a>', ""))
        header = (
            f'<div class="api-item" id="{anchor}">'
            f'<div class="api-sig">{sig_html(sig_of(t))}</div>'
            f"{render_desc(desc.get(t['name'], ''))}"
        )
        if t["members"]:
            header += '<div class="api-sub">'
            for mbr in t["members"]:
                header += f'<div class="api-sig api-sig--variant">{sig_html(mbr)}</div>'
            header += "</div>"
        header += "</div>"
        body.append(header)
        for m in t["methods"]:
            manchor = f"m-{t['name']}-{m['name']}"
            toc.append((f'<a href="#{manchor}" class="toc-sub">{t["name"]}.{m["name"]}</a>', ""))
            body.append(api_item(manchor, m["sig"], f"{t['name']}::{m['name']}", desc, m["name"]))
    body.append("</div>")

    # ---- errors ----
    body.append('<div class="api-group"><h2 id="errors">Errors</h2>')
    toc.append(('<div class="toc__h">Errors</div>', ""))
    for t in errors:
        anchor = "t-" + t["name"]
        toc.append((f'<a href="#{anchor}">{t["name"]}</a>', ""))
        header = (
            f'<div class="api-item" id="{anchor}">'
            f'<div class="api-sig">{sig_html(sig_of(t))}</div>'
            f"{render_desc(desc.get(t['name'], ''))}"
        )
        if t["members"]:
            header += '<div class="api-sub">'
            for mbr in t["members"]:
                vname = re.match(r"([A-Za-z0-9_]+)", mbr)
                vdoc = variants.get(vname.group(1)) if vname else None
                row = f'<div class="api-var"><div class="api-sig api-sig--variant">{sig_html(mbr)}</div>'
                if vdoc:
                    row += f'<div class="api-vdoc">{render_desc(vdoc)}</div>'
                row += "</div>"
                header += row
            header += "</div>"
        header += "</div>"
        body.append(header)
    body.append("</div>")

    toc_html = "\n".join(link for link, _ in toc)
    body_html = "\n".join(body)

    page = TEMPLATE.format(toc=toc_html, body=body_html)
    OUT.write_text(page, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)}")


def sig_of(t):
    kw = {"struct": "pub(all) struct", "suberror": "pub(all) suberror", "type": "type"}[t["kind"]]
    return f'{kw} {t["name"]}'


TEMPLATE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API reference — moonmime</title>
<meta name="description" content="Every public value, type, method, and error in moonmime, generated from the package interface and its documentation comments.">
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='7' fill='%234E56C0'/><path d='M0 21 L32 9 L32 32 L0 32Z' fill='%239B5DE0'/><path d='M0 26 L32 16 L32 32 L0 32Z' fill='%23D78FEE'/><path d='M0 30 L32 23 L32 32 L0 32Z' fill='%23FDCFFA'/></svg>">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,400;9..144,600;9..144,800&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="assets/css/style.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>

<nav class="nav">
  <a class="nav__brand" href="index.html"><span class="dot"></span>moonmime</a>
  <button class="nav__icon nav__menu" type="button" aria-label="Menu" aria-expanded="false">
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true"><path d="M4 7h16M4 12h16M4 17h16"/></svg>
  </button>
  <div class="nav__links">
    <a class="nav__link" href="index.html">Home</a>
    <a class="nav__link" href="guide.html">Guide</a>
    <a class="nav__link is-active" href="api.html">API</a>
    <a class="nav__link" href="showcase.html">Showcase</a>
    <a class="nav__icon" href="https://github.com/moonbitstack/moonmime" aria-label="GitHub repository" title="GitHub">
      <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 .5C5.73.5.5 5.73.5 12a11.5 11.5 0 0 0 7.86 10.92c.58.1.79-.25.79-.56v-2c-3.2.7-3.88-1.37-3.88-1.37-.53-1.34-1.3-1.7-1.3-1.7-1.06-.72.08-.71.08-.71 1.17.08 1.79 1.2 1.79 1.2 1.04 1.79 2.73 1.27 3.4.97.1-.76.41-1.27.74-1.56-2.55-.29-5.23-1.28-5.23-5.7 0-1.26.45-2.29 1.19-3.1-.12-.29-.52-1.46.11-3.05 0 0 .97-.31 3.18 1.18a11 11 0 0 1 5.8 0c2.2-1.49 3.17-1.18 3.17-1.18.63 1.59.23 2.76.11 3.05.74.81 1.19 1.84 1.19 3.1 0 4.43-2.69 5.41-5.25 5.69.42.36.79 1.08.79 2.18v3.23c0 .31.21.67.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.73 18.27.5 12 .5Z"/></svg>
    </a>
    <button class="nav__icon nav__toggle" type="button" aria-label="Toggle theme" aria-pressed="false" title="Toggle theme">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" aria-hidden="true"><path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8Z"/></svg>
    </button>
  </div>
</nav>

<main id="main" class="wrap section">
  <div class="docs">
    <aside class="toc">
{toc}
    </aside>
    <div class="content">
      <span class="eyebrow">API reference</span>
      <h2 class="page-title">The whole surface.</h2>
      <p class="lead">Every public value, type, method, and error, grouped by package and ordered for lookup. Generated from the package interface and the source comments.</p>
{body}
    </div>
  </div>
</main>

<footer class="footer">
  <div class="wrap footer__row">
    <span>moonmime · Apache-2.0</span>
    <span>
      <a href="https://github.com/moonbitstack/moonmime">GitHub</a> ·
      <a href="https://mooncakes.io">mooncakes</a> ·
      <a href="guide.html">Guide</a> ·
      <a href="api.html">API</a>
    </span>
  </div>
</footer>

<script src="assets/js/site.js" defer></script>
</body>
</html>
"""


if __name__ == "__main__":
    build()
