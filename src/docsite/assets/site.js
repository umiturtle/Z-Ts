/* ziggurats documentation site — vanilla JS, no build step, no dependency.
 *
 * Everything here is progressive enhancement: with JS disabled the pages still read, the code
 * blocks still scroll, and every navigation link is a real <a href>.
 *
 *   1. theme          — explicit choice remembered, `prefers-color-scheme` as the seed
 *   2. code blocks    — language label + copy button (wraps the generated <pre>)
 *   3. search         — over `window.ZTS_SEARCH`, same-language hits first
 *   4. sidebar        — off-canvas on mobile, with a backdrop and Escape
 *   5. table of contents — highlights the section you are reading
 *   6. reading progress bar
 */
(function () {
  "use strict";

  var doc = document;
  var html = doc.documentElement;
  var body = doc.body;
  var lang = (body && body.getAttribute("data-lang")) || "ja";
  var isJa = lang === "ja";

  /* ------------------------------------------------------------- 1. theme */

  var themeBtn = doc.querySelector("[data-theme-toggle]");

  function applyTheme(theme) {
    html.dataset.theme = theme;
    try { localStorage.setItem("zts-theme", theme); } catch (e) { /* private mode */ }
    if (themeBtn) {
      themeBtn.setAttribute("aria-label", theme === "dark"
        ? (isJa ? "ライトモードにする" : "Switch to light mode")
        : (isJa ? "ダークモードにする" : "Switch to dark mode"));
      themeBtn.setAttribute("aria-pressed", theme === "dark" ? "true" : "false");
    }
  }

  // The inline script in <head> already picked a theme before paint; fall back to it when the
  // page was cached without the script running.
  if (!html.dataset.theme) {
    var media = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)");
    applyTheme(media && media.matches ? "dark" : "light");
  } else {
    applyTheme(html.dataset.theme);
  }

  if (themeBtn) {
    themeBtn.addEventListener("click", function () {
      applyTheme(html.dataset.theme === "dark" ? "light" : "dark");
    });
  }

  // Follow the OS only while the reader has not expressed a preference of their own.
  if (window.matchMedia) {
    var mq = window.matchMedia("(prefers-color-scheme: dark)");
    var onScheme = function (event) {
      var stored = null;
      try { stored = localStorage.getItem("zts-theme"); } catch (e) { /* ignore */ }
      if (!stored) applyTheme(event.matches ? "dark" : "light");
    };
    if (mq.addEventListener) mq.addEventListener("change", onScheme);
    else if (mq.addListener) mq.addListener(onScheme);
  }

  /* -------------------------------------------------------- 2. code blocks */

  var COPY = isJa ? "コピー" : "Copy";
  var COPIED = isJa ? "コピー済み" : "Copied";

  doc.querySelectorAll("pre.code").forEach(function (pre) {
    var code = pre.querySelector("code");
    var langClass = code ? Array.prototype.find.call(code.classList, function (c) {
      return c.indexOf("language-") === 0;
    }) : null;
    var language = langClass ? langClass.replace("language-", "") : "";

    var wrap = doc.createElement("div");
    wrap.className = "code-block";
    pre.parentNode.insertBefore(wrap, pre);
    wrap.appendChild(pre);

    var head = doc.createElement("div");
    head.className = "code-head";
    var dot = doc.createElement("span");
    dot.className = "code-dot";
    head.appendChild(dot);
    if (language) {
      var label = doc.createElement("span");
      label.textContent = language;
      head.appendChild(label);
    }

    var button = doc.createElement("button");
    button.type = "button";
    button.className = "copy";
    button.textContent = COPY;
    button.addEventListener("click", function () {
      var text = code ? code.textContent : pre.textContent;
      var done = function () {
        button.textContent = COPIED;
        button.classList.add("done");
        setTimeout(function () {
          button.textContent = COPY;
          button.classList.remove("done");
        }, 1500);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(done, function () { /* ignore */ });
      } else {
        var area = doc.createElement("textarea");
        area.value = text;
        area.setAttribute("aria-hidden", "true");
        area.style.position = "fixed";
        area.style.opacity = "0";
        body.appendChild(area);
        area.select();
        try { doc.execCommand("copy"); done(); } catch (e) { /* ignore */ }
        body.removeChild(area);
      }
    });
    head.appendChild(button);
    wrap.insertBefore(head, pre);
  });

  /* -------------------------------------------------------------- 3. search */

  var input = doc.getElementById("search");
  var results = doc.getElementById("search-results");
  var index = window.ZTS_SEARCH || [];
  // Pages live at different depths (`docs/tasks/x.html`), so hits resolve against the site root
  // recorded on <body>.
  var siteRoot = (body && body.getAttribute("data-root")) || "";

  function fold(text) { return (text || "").toLowerCase(); }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (ch) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[ch];
    });
  }

  function snippet(text, needle) {
    var at = fold(text).indexOf(needle);
    if (at < 0) return escapeHtml(text.slice(0, 100)) + (text.length > 100 ? "…" : "");
    var start = Math.max(0, at - 36);
    var slice = text.slice(start, start + 132).replace(/\s+/g, " ");
    var offset = at - start;
    return (start > 0 ? "…" : "") +
      escapeHtml(slice.slice(0, offset)) +
      "<mark>" + escapeHtml(slice.slice(offset, offset + needle.length)) + "</mark>" +
      escapeHtml(slice.slice(offset + needle.length)) +
      (start + 132 < text.length ? "…" : "");
  }

  function render(query) {
    if (!results) return;
    var needle = fold(query.trim());
    results.textContent = "";
    if (needle.length < 1) { results.hidden = true; return; }

    var hits = [];
    for (var i = 0; i < index.length; i++) {
      var entry = index[i];
      var title = fold(entry.t);
      var haystack = fold(entry.x);
      var inTitle = title.indexOf(needle);
      var inBody = haystack.indexOf(needle);
      if (inTitle < 0 && inBody < 0) continue;

      // Score: same language first, then title matches, then shorter titles (best matches are
      // usually the exact declaration the reader typed).
      var score = 0;
      if (entry.l && entry.l !== lang) score += 4;
      if (inTitle < 0) score += 2;
      else if (inTitle === 0) score -= 1;
      if (entry.u.indexOf("docs/api/") !== -1) score += 1;
      hits.push({ entry: entry, score: score, titleLen: entry.t.length });
    }
    hits.sort(function (a, b) {
      if (a.score !== b.score) return a.score - b.score;
      if (a.titleLen !== b.titleLen) return a.titleLen - b.titleLen;
      return a.entry.t < b.entry.t ? -1 : 1;
    });

    if (hits.length === 0) {
      var empty = doc.createElement("li");
      empty.className = "empty";
      empty.textContent = isJa ? "ヒットなし" : "No matches";
      results.appendChild(empty);
      results.hidden = false;
      return;
    }

    hits.slice(0, 20).forEach(function (hit) {
      var li = doc.createElement("li");
      var a = doc.createElement("a");
      a.href = siteRoot + hit.entry.u;
      a.innerHTML = escapeHtml(hit.entry.t) +
        '<span class="group">' + escapeHtml(hit.entry.g || "") + " · " +
        snippet(hit.entry.x || "", needle) + "</span>";
      li.appendChild(a);
      results.appendChild(li);
    });
    results.hidden = false;
  }

  if (input) {
    input.addEventListener("input", function () { render(input.value); });
    input.addEventListener("focus", function () { if (input.value) render(input.value); });
    input.addEventListener("keydown", function (event) {
      if (event.key === "Escape") {
        input.value = "";
        render("");
        input.blur();
      } else if (event.key === "Enter") {
        var first = results && results.querySelector("a");
        if (first) window.location.href = first.getAttribute("href");
      } else if (event.key === "ArrowDown") {
        var next = results && results.querySelector("a");
        if (next) { event.preventDefault(); next.focus(); }
      }
    });
    doc.addEventListener("keydown", function (event) {
      var tag = (event.target.tagName || "").toLowerCase();
      var typing = tag === "input" || tag === "textarea" || event.target.isContentEditable;
      if (event.key === "/" && !typing) {
        event.preventDefault();
        input.focus();
        input.select();
      }
    });
    doc.addEventListener("click", function (event) {
      if (results && !results.hidden && !event.target.closest(".search")) results.hidden = true;
    });
  }

  /* ------------------------------------------------------------- 4. sidebar */

  var menu = doc.querySelector("[data-menu-toggle]");
  var sidebar = doc.querySelector(".sidebar");
  if (menu && sidebar) {
    var setOpen = function (open) {
      sidebar.classList.toggle("open", open);
      body.classList.toggle("nav-open", open);
      menu.setAttribute("aria-expanded", open ? "true" : "false");
    };
    menu.addEventListener("click", function () {
      setOpen(!sidebar.classList.contains("open"));
    });
    sidebar.addEventListener("click", function (event) {
      if (event.target.tagName === "A") setOpen(false);
    });
    doc.addEventListener("keydown", function (event) {
      if (event.key === "Escape") setOpen(false);
    });
    doc.addEventListener("click", function (event) {
      if (!sidebar.classList.contains("open")) return;
      if (sidebar.contains(event.target) || menu.contains(event.target)) return;
      setOpen(false);
    });
  }

  /* ------------------------------------------------- 5. table of contents */

  var tocLinks = doc.querySelectorAll(".toc a[href^='#']");
  if (tocLinks.length && "IntersectionObserver" in window) {
    var byId = {};
    var headings = [];
    tocLinks.forEach(function (link) {
      var id = decodeURIComponent(link.getAttribute("href").slice(1));
      var target = doc.getElementById(id);
      if (target) { byId[id] = link; headings.push(target); }
    });

    var active = null;
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var link = byId[entry.target.id];
        if (!link || link === active) return;
        if (active) active.classList.remove("active");
        link.classList.add("active");
        active = link;
      });
    }, { rootMargin: "-72px 0px -70% 0px", threshold: 0 });

    headings.forEach(function (heading) { observer.observe(heading); });
  }

  /* ---------------------------------------------------- 6. reading progress */

  var bar = doc.createElement("div");
  bar.className = "scroll-progress";
  bar.setAttribute("aria-hidden", "true");
  body.appendChild(bar);

  var updateProgress = function () {
    var scrollable = doc.documentElement.scrollHeight - window.innerHeight;
    var ratio = scrollable > 0 ? Math.min(1, window.scrollY / scrollable) : 0;
    bar.style.width = (ratio * 100).toFixed(2) + "%";
  };
  window.addEventListener("scroll", updateProgress, { passive: true });
  window.addEventListener("resize", updateProgress);
  updateProgress();
})();
