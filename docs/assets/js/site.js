// moonmime docs — shared behaviour: theme, copy buttons, scroll-spy.
(function () {
  "use strict";

  var root = document.documentElement;

  // ---- theme ----
  function applyTheme(t) {
    if (t === "dark") root.setAttribute("data-theme", "dark");
    else root.removeAttribute("data-theme");
    var btn = document.querySelector(".nav__toggle");
    if (btn) btn.setAttribute("aria-pressed", String(t === "dark"));
    try { localStorage.setItem("moonmime-theme", t); } catch (e) {}
  }
  var saved;
  try { saved = localStorage.getItem("moonmime-theme"); } catch (e) {}
  if (!saved) saved = window.matchMedia &&
    window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  applyTheme(saved);

  document.querySelectorAll(".nav__toggle").forEach(function (b) {
    b.addEventListener("click", function () {
      var now = root.getAttribute("data-theme") === "dark" ? "light" : "dark";
      applyTheme(now);
    });
  });

  // ---- mobile menu ----
  var menuBtn = document.querySelector(".nav__menu");
  var navEl = document.querySelector(".nav");
  if (menuBtn && navEl) {
    menuBtn.addEventListener("click", function () {
      var open = navEl.classList.toggle("is-open");
      menuBtn.setAttribute("aria-expanded", String(open));
    });
    navEl.querySelectorAll(".nav__links a").forEach(function (a) {
      a.addEventListener("click", function () {
        navEl.classList.remove("is-open");
        menuBtn.setAttribute("aria-expanded", "false");
      });
    });
  }

  // ---- copy buttons ----
  document.querySelectorAll(".copy").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var block = btn.closest(".codeblock") || btn.parentElement;
      var code = block.querySelector("pre code") || block.querySelector("pre");
      if (!code) return;
      var text = code.innerText;
      navigator.clipboard.writeText(text).then(function () {
        var old = btn.textContent;
        btn.textContent = "copied";
        setTimeout(function () { btn.textContent = old; }, 1200);
      });
    });
  });

  // ---- scroll-spy for docs TOC ----
  var tocLinks = Array.prototype.slice.call(document.querySelectorAll(".toc a"));
  if (tocLinks.length) {
    var ids = tocLinks.map(function (a) { return a.getAttribute("href").slice(1); });
    var sections = ids.map(function (id) { return document.getElementById(id); }).filter(Boolean);
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) {
          tocLinks.forEach(function (a) {
            a.classList.toggle("is-active", a.getAttribute("href") === "#" + en.target.id);
          });
        }
      });
    }, { rootMargin: "-80px 0px -70% 0px", threshold: 0 });
    sections.forEach(function (s) { io.observe(s); });
  }
})();
