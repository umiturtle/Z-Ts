// Injected by `examples/gallery/src/main.zig` at DOCUMENT_START, right after the unmodified
// `zts_tauri.js_bootstrap` script installs `window.__TAURI_INTERNALS__.invoke`.
//
// This is the *only* bridge between the nine framework demos and the Zig host. A static GitHub
// Pages demo has neither this file nor the bootstrap, so `window.__ZTS_ZIG__` is undefined and
// the shared `.zigbar` panel stays at `ZIG OFFLINE` with both buttons disabled. The seal below
// can only be produced by `zig_probe` / `zig_inc` / `zig_dec` inside the Zig binary: the secret
// and the SHA-256 construction never appear in any `.html` or `.js` shipped to Pages.
(function () {
  // Read lazily: init-script ordering is backend-specific, and a page can be re-navigated.
  function internals() { return window.__TAURI_INTERNALS__; }
  var posted = false;
  var done = false;

  function el(key) { return document.querySelector('[data-zts="' + key + '"]'); }
  function post(payload) {
    try { window.__ztsPostMessage(JSON.stringify(payload)); } catch (e) {}
  }
  function ready() {
    if (posted) return;
    posted = true;
    post({ app: 'ready' });
  }
  function call(cmd) {
    var inv = internals();
    if (!inv || typeof inv.invoke !== 'function') {
      return Promise.reject(new Error('no Zig host'));
    }
    return inv.invoke(cmd, {});
  }
  function valid(info) {
    return !!info && typeof info.seal === 'string' &&
      info.seal.length === 16 && typeof info.count === 'number' && info.ok === true;
  }
  function paint(info) {
    var badge = el('zig-state');
    if (!badge || !valid(info)) return false;
    badge.textContent = 'ZIG ONLINE';
    badge.setAttribute('data-online', 'true');
    el('zig-seal').textContent = info.seal;
    el('zig-count').textContent = String(info.count);
    el('zig-hint').textContent = 'Zig が計算 / computed by Zig';
    el('zig-inc').disabled = false;
    el('zig-dec').disabled = false;
    return true;
  }
  function step(delta) {
    call(delta > 0 ? 'zig_inc' : 'zig_dec').then(function (info) {
      if (!valid(info)) return;
      el('zig-seal').textContent = info.seal;
      el('zig-count').textContent = String(info.count);
    })['catch'](function () {});
  }
  function mount() {
    if (done) return;
    // Framework lifecycle hooks run after their own DOM was rendered (useEffect / onMount /
    // onMounted / ngAfterViewInit / <script>), but guard anyway for hydration edge cases.
    if (!el('zig-panel')) { setTimeout(mount, 40); return; }
    done = true;
    var inv = internals();
    if (!inv || typeof inv.invoke !== 'function') { ready(); return; }
    // A hung custom-protocol request must never block the screenshot pipeline forever. The
    // 8s guard is far below the gallery's 20s app-ready timeout, and late results are ignored.
    var guard = setTimeout(function () { if (!posted) ready(); }, 8000);
    call('zig_probe').then(function (info) {
      if (posted) return;                 // guard already fired: keep the pixels deterministic
      clearTimeout(guard);
      paint(info);
      el('zig-inc').addEventListener('click', function () { step(1); });
      el('zig-dec').addEventListener('click', function () { step(-1); });
      ready();
      post({ app: 'zig', online: valid(info) });
    })['catch'](function () {
      clearTimeout(guard);
      ready();
    });
  }

  window.__ZTS_ZIG__ = {
    mount: mount,
    probe: function () { return call('zig_probe'); },
    step: function (delta) { return call(delta > 0 ? 'zig_inc' : 'zig_dec'); }
  };
})();
