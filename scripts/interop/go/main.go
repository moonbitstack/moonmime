// The Go side of the multipart interop check.
//
// It speaks the same exchange contract as the MoonBit program and the Python
// partner: one sheet per case in, one body and one Content-Type out; then one
// body in, one report of what the Go standard library read out of it.
//
//	go run main.go write <directory>
//	go run main.go read <directory>
//
// A sheet is one case, one clause a line, every payload base64 (`-` for
// nothing): `kind`, `boundary`, `related`, `header`, `field`, `file`, `part`.
// See scripts/check_multipart_interop.py for the whole of it.
package main

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/textproto"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type part struct {
	headers [][2]string
	content []byte
}

type file struct {
	name        string
	filename    string
	contentType string
	content     []byte
}

type sheet struct {
	id          string
	kind        string
	boundary    string
	relatedType string
	relatedName string
	relatedInfo string
	header      string
	fields      [][2]string
	files       []file
	parts       []part
}

func main() {
	if len(os.Args) != 3 {
		fail("usage: interop write|read <directory>")
	}
	switch os.Args[1] {
	case "write":
		forEachSheet(os.Args[2], writeCase)
	case "read":
		forEachSheet(os.Args[2], readCase)
	default:
		fail("usage: interop write|read <directory>")
	}
}

func fail(why string) {
	fmt.Fprintln(os.Stderr, "interop: "+why)
	os.Exit(2)
}

func forEachSheet(dir string, leg func(string, sheet)) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		fail("cannot list " + dir + ": " + err.Error())
	}
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	for _, name := range names {
		if !strings.HasSuffix(name, ".sheet") {
			continue
		}
		text, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			fail("cannot read " + name + ": " + err.Error())
		}
		leg(dir, parseSheet(strings.TrimSuffix(name, ".sheet"), string(text)))
	}
}

func parseSheet(id, text string) sheet {
	sh := sheet{id: id, kind: "form-data"}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if line == "" {
			continue
		}
		words := strings.Split(line, " ")
		switch words[0] {
		case "kind":
			if len(words) == 2 && (words[1] == "mixed" || words[1] == "related") {
				sh.kind = words[1]
			}
		case "boundary":
			sh.boundary = string(uncell(words[1]))
		case "related":
			sh.relatedType = string(uncell(words[1]))
			sh.relatedName = string(uncell(words[2]))
			sh.relatedInfo = string(uncell(words[3]))
		case "header":
			sh.header = string(uncell(words[1]))
		case "field":
			sh.fields = append(sh.fields, [2]string{string(uncell(words[1])), string(uncell(words[2]))})
		case "file":
			sh.files = append(sh.files, file{
				name:        string(uncell(words[1])),
				filename:    string(uncell(words[2])),
				contentType: string(uncell(words[3])),
				content:     uncell(words[4]),
			})
		case "part":
			sh.parts = append(sh.parts, part{
				headers: parseHeaderBlock(string(uncell(words[1]))),
				content: uncell(words[2]),
			})
		default:
			fail("case " + id + ": cannot read the line " + line)
		}
	}
	return sh
}

func parseHeaderBlock(block string) [][2]string {
	out := [][2]string{}
	for _, line := range strings.Split(block, "\r\n") {
		if at := strings.Index(line, ":"); at > 0 {
			out = append(out, [2]string{line[:at], strings.TrimSpace(line[at+1:])})
		}
	}
	return out
}

func writeCase(dir string, sh sheet) {
	var buf bytes.Buffer
	w := multipart.NewWriter(&buf)
	if sh.boundary != "" {
		if err := w.SetBoundary(sh.boundary); err != nil {
			fail("case " + sh.id + ": " + err.Error())
		}
	}
	if sh.kind == "form-data" {
		for _, field := range sh.fields {
			if err := w.WriteField(field[0], field[1]); err != nil {
				fail("case " + sh.id + ": " + err.Error())
			}
		}
		for _, one := range sh.files {
			header := make(textproto.MIMEHeader)
			header.Set("Content-Disposition", fmt.Sprintf(
				`form-data; name="%s"; filename="%s"`, escape(one.name), escape(one.filename)))
			if one.contentType != "" {
				header.Set("Content-Type", one.contentType)
			}
			writer, err := w.CreatePart(header)
			if err != nil {
				fail("case " + sh.id + ": " + err.Error())
			}
			writer.Write(one.content)
		}
	} else {
		for _, one := range sh.parts {
			header := make(textproto.MIMEHeader)
			for _, pair := range one.headers {
				header.Set(pair[0], pair[1])
			}
			writer, err := w.CreatePart(header)
			if err != nil {
				fail("case " + sh.id + ": " + err.Error())
			}
			writer.Write(one.content)
		}
	}
	if err := w.Close(); err != nil {
		fail("case " + sh.id + ": " + err.Error())
	}
	write(filepath.Join(dir, sh.id+".out.body"), buf.Bytes())
	write(filepath.Join(dir, sh.id+".out.type"), []byte(contentType(sh.kind, w.Boundary(), sh)))
}

func readCase(dir string, sh sheet) {
	body, err := os.ReadFile(filepath.Join(dir, sh.id+".body"))
	if err != nil {
		fail("cannot read " + sh.id + ".body: " + err.Error())
	}
	reader := multipart.NewReader(bytes.NewReader(body), sh.boundary)
	var out strings.Builder
	root := ""
	related := map[string]string{}
	if sh.kind == "related" {
		_, params, err := mime.ParseMediaType(sh.header)
		if err != nil {
			fail("case " + sh.id + ": " + err.Error())
		}
		for _, key := range []string{"type", "start", "start-info"} {
			related[key] = params[key]
		}
		fmt.Fprintf(&out, "related %s %s %s\n",
			cell([]byte(related["type"])), cell([]byte(related["start"])),
			cell([]byte(related["start-info"])))
	}
	for {
		p, err := reader.NextPart()
		if err == io.EOF {
			break
		}
		if err != nil {
			fail("case " + sh.id + ": " + err.Error())
		}
		content, err := io.ReadAll(p)
		if err != nil {
			fail("case " + sh.id + ": " + err.Error())
		}
		if sh.kind == "form-data" {
			if p.FileName() != "" {
				fmt.Fprintf(&out, "file %s %s %s %s\n",
					cell([]byte(p.FormName())), cell([]byte(p.FileName())),
					cell([]byte(p.Header.Get("Content-Type"))), cell(content))
			} else {
				fmt.Fprintf(&out, "field %s %s\n",
					cell([]byte(p.FormName())), cell(content))
			}
		} else {
			fmt.Fprintf(&out, "part %s %s\n",
				cell([]byte(p.Header.Get("Content-Type"))), cell(content))
			if sh.kind == "related" && root == "" {
				if related["start"] == "" {
					root = fmt.Sprintf("root %s %s\n",
						cell([]byte(p.Header.Get("Content-Type"))), cell(content))
				} else if stripped(p.Header.Get("Content-ID")) == stripped(related["start"]) {
					root = fmt.Sprintf("root %s %s\n",
						cell([]byte(p.Header.Get("Content-Type"))), cell(content))
				}
			}
		}
	}
	if sh.kind == "related" {
		if root == "" {
			out.WriteString("root - -\n")
		} else {
			out.WriteString(root)
		}
	}
	write(filepath.Join(dir, sh.id+".out.read"), []byte(out.String()))
}

// contentType names the body as RFC 2046 asks, quoting a boundary that is not a
// token so that the header keeps it in one piece. A related body also carries
// the parameters of RFC 2387, quoted because none of them is a token.
func contentType(kind, boundary string, sh sheet) string {
	header := contentTypeOf(kind, boundary)
	if kind == "related" {
		for _, one := range [][2]string{
			{"type", sh.relatedType},
			{"start", sh.relatedName},
			{"start-info", sh.relatedInfo},
		} {
			if one[1] != "" {
				header += fmt.Sprintf(`; %s="%s"`, one[0], escape(one[1]))
			}
		}
	}
	return header
}

// contentTypeOf is the subtype and its boundary, without the parameters a
// related body adds.
func contentTypeOf(kind, boundary string) string {
	for _, c := range boundary {
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' {
			continue
		}
		switch c {
		case '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~':
			continue
		}
		return fmt.Sprintf(`multipart/%s; boundary="%s"`, kind, escape(boundary))
	}
	return fmt.Sprintf("multipart/%s; boundary=%s", kind, boundary)
}

// stripped is a content ID as it is compared: the address inside the brackets.
func stripped(contentID string) string {
	text := strings.TrimSpace(contentID)
	if len(text) >= 2 && text[0] == '<' && text[len(text)-1] == '>' {
		return text[1 : len(text)-1]
	}
	return text
}

func escape(value string) string {
	return strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(value)
}

func cell(data []byte) string {
	if len(data) == 0 {
		return "-"
	}
	return base64.StdEncoding.EncodeToString(data)
}

func uncell(word string) []byte {
	if word == "-" || word == "" {
		return []byte{}
	}
	data, err := base64.StdEncoding.DecodeString(word)
	if err != nil {
		fail("cannot read the cell " + word)
	}
	return data
}

func write(path string, data []byte) {
	if err := os.WriteFile(path, data, 0o644); err != nil {
		fail("cannot write " + path + ": " + err.Error())
	}
}
