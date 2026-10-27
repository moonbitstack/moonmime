// moonmime docs — live demos backed by the real library compiled to JS.
// The compiled module (examples/browser -> browser.js) is built in CI and by
// the local preview; if it is missing the widgets say so instead of breaking.
let M = null;
try {
  M = await import("./browser.js");
} catch (e) {
  document.querySelectorAll("[data-demo]").forEach(function (el) {
    el.classList.add("empty");
    el.textContent = "Demo module not built. Run `moon build --target js` and reload.";
  });
}

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"]/g, function (c) {
    return c === "&" ? "&amp;" : c === "<" ? "&lt;" : c === ">" ? "&gt;" : "&quot;";
  });
}
function truncate(s, n) {
  s = String(s == null ? "" : s);
  return s.length > n ? s.slice(0, n) + "…" : s;
}

// ---------------- homepage live widget ----------------
var dFile = document.getElementById("d-filename");
if (dFile && M) {
  var dType = document.getElementById("d-type");
  var dExt = document.getElementById("d-ext");
  var dCd = document.getElementById("d-cd");
  var dInline = document.getElementById("d-inline");
  function runHome() {
    var name = dFile.value;
    var type = M.browser_guess_type(name);
    var ext = M.browser_guess_extension(type);
    dType.innerHTML = '<span class="k">type        </span> <span class="v">' + esc(type) + "</span>";
    dExt.innerHTML = '<span class="k">extension   </span> <span class="v">' + esc(ext || "—") + "</span>";
    var inline = dInline && dInline.checked;
    dCd.innerHTML = '<span class="k">disposition </span> ' +
      esc(M.browser_content_disposition(name, inline));
  }
  dFile.addEventListener("input", runHome);
  if (dInline) dInline.addEventListener("change", runHome);
  runHome();
}

// ---------------- showcase: filename <-> MIME ----------------
var sName = document.getElementById("s-name");
if (sName && M) {
  var sType = document.getElementById("s-type");
  var sNameOut = document.getElementById("s-name-out");
  var sTypeOut = document.getElementById("s-type-out");
  function nameRun() {
    var t = M.browser_guess_type(sName.value);
    sNameOut.innerHTML = '<span class="k">→ </span><span class="v">' + esc(t) + "</span>";
  }
  function typeRun() {
    var e = M.browser_guess_extension(sType.value);
    sTypeOut.innerHTML = '<span class="k">→ </span><span class="v">' + esc(e || "(unknown)") + "</span>";
  }
  sName.addEventListener("input", nameRun);
  sType.addEventListener("input", typeRun);
  document.querySelectorAll("[data-fill]").forEach(function (chip) {
    chip.addEventListener("click", function () {
      var kind = chip.getAttribute("data-fill");
      var val = chip.getAttribute("data-val");
      if (kind === "name") { sName.value = val; nameRun(); }
      else { sType.value = val; typeRun(); }
    });
  });
  nameRun();
  typeRun();
}

// ---------------- showcase: multipart explorer ----------------
var mpBody = document.getElementById("mp-body");
if (mpBody && M) {
  var mpBoundary = document.getElementById("mp-boundary");
  var mpOut = document.getElementById("mp-out");
  var mpForm = document.getElementById("mp-form");

  if (!mpBody.value) {
    mpBody.value =
      "------edge\r\n" +
      'Content-Disposition: form-data; name="recipe"\r\n' +
      "\r\n" +
      "chiles en nogada\r\n" +
      "------edge\r\n" +
      'Content-Disposition: form-data; name="photo"; filename="platillo.png"\r\n' +
      "Content-Type: image/png\r\n" +
      "\r\n" +
      "PNGDATA\r\n" +
      "------edge--\r\n";
  }

  function renderParts(json) {
    var data;
    try { data = JSON.parse(json); } catch (e) { mpOut.innerHTML = ""; return; }
    if (data.error) {
      mpOut.innerHTML = '<div class="part"><div class="part__h">this body could not be read as multipart</div></div>';
      return;
    }
    if (!data.length) {
      mpOut.innerHTML = '<div class="part"><div class="part__h">no parts found — check the boundary</div></div>';
      return;
    }
    var html = "";
    data.forEach(function (p, i) {
      var name = p.name == null ? '<span style="opacity:.55">none</span>' : "<b>" + esc(p.name) + "</b>";
      var fn = p.filename == null ? "" :
        '<div class="part__kv"><b>filename</b> ' + esc(p.filename) + "</div>";
      html += '<div class="part">' +
        '<div class="part__h">part ' + (i + 1) + " · " + p.size + " bytes</div>" +
        '<div class="part__kv"><b>name</b> ' + name + "</div>" +
        fn +
        '<div class="part__kv"><b>Content-Type</b> ' + (p.content_type ? esc(p.content_type) : '<span style="opacity:.55">none</span>') + "</div>" +
        '<div class="part__kv"><b>body</b> ' + esc(truncate(p.body, 140)) + "</div>" +
        "</div>";
    });
    mpOut.innerHTML = html;
  }

  function renderForm(json) {
    if (!mpForm) return;
    var fd;
    try { fd = JSON.parse(json); } catch (e) { return; }
    if (fd.error) { mpForm.innerHTML = ""; return; }
    var html = '<span class="chip">fields ' + fd.fields.length + "</span>" +
      '<span class="chip">files ' + fd.files.length + "</span>";
    fd.fields.forEach(function (f) {
      html += '<span class="chip">' + esc(f.name) + "=" + esc(truncate(f.value, 22)) + "</span>";
    });
    fd.files.forEach(function (f) {
      html += '<span class="chip">' + esc(f.filename) + " · " + f.size + "B</span>";
    });
    mpForm.innerHTML = html;
  }

  function runMp() {
    // A textarea hands back LF only; an HTTP body uses CRLF, which is what the
    // multipart grammar expects. Restore CRLF before handing it to the library.
    var body = mpBody.value.replace(/\r?\n/g, "\r\n");
    var boundary = mpBoundary.value.trim();
    renderParts(M.browser_multipart(body, boundary));
    renderForm(M.browser_formdata(body, boundary));
  }
  document.getElementById("mp-run").addEventListener("click", runMp);
  [mpBody, mpBoundary].forEach(function (el) {
    el.addEventListener("input", runMp);
  });
  runMp();
}
