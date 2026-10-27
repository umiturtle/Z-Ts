<script>
  let count = 0;
  import { onMount } from 'svelte';
  onMount(() => {
    if (typeof document === 'undefined') return;
    document.querySelector('[data-zts="status"]').textContent = 'mounted';
    const zts = window.__ztsPostMessage; if (zts) zts(JSON.stringify({ app: "ready" }));
  });
</script>

<div class="shell">
  <header class="head">
    <div class="brand">
      <div class="logo">ZT</div>
      <div>
        <div class="title">Z-Ts × SvelteKit</div>
        <div class="sub">Zig 製 WebView で動く SvelteKit 3.1 の静的ビルド</div>
      </div>
    </div>
    <div class="badge">SvelteKit 3.1</div>
  </header>
  <section class="card">
    <div class="counter">
      <div class="value" data-zts="count">{count}</div>
      <button on:click={() => (count -= 1)} data-zts="dec">−</button>
      <button class="primary" on:click={() => (count += 1)} data-zts="inc">＋</button>
    </div>
    <ul class="features">
      <li><b>同じ HTML</b>3 OS で同一の画素</li>
      <li><b>同じフォント</b>同梱 woff2 のみ</li>
      <li><b>同じ寸法</b>760×520 固定</li>
    </ul>
    <div class="meta">
      <span data-zts="status">mounted</span>
      <span class="tag">tauri://localhost</span>
    </div>
  </section>
</div>

<style>/* Z-Ts framework demo — 3 OS で同一画素にするためシステムフォントを使わない。 */
@font-face { font-family:"ZTS Sans"; font-style:normal; font-weight:400; font-display:block;
  src:url("/zts/fonts/zts-sans-400.woff2") format("woff2"); }
@font-face { font-family:"ZTS Sans"; font-style:normal; font-weight:700; font-display:block;
  src:url("/zts/fonts/zts-sans-700.woff2") format("woff2"); }
@font-face { font-family:"ZTS Mono"; font-style:normal; font-weight:400; font-display:block;
  src:url("/zts/fonts/zts-mono-400.woff2") format("woff2"); }
* { box-sizing:border-box; }
html,body { margin:0; padding:0; height:100%; }
body { font-family:"ZTS Sans"; font-size:15px; line-height:1.6; color:#0f172a; background:#f4f6fb;
  -webkit-font-smoothing:antialiased; text-rendering:geometricPrecision; font-kerning:normal;
  font-synthesis:none; }
.shell { width:760px; margin:0 auto; padding:28px 32px 32px; }
.head { display:flex; align-items:center; justify-content:space-between; }
.brand { display:flex; align-items:center; gap:12px; }
.logo { width:38px; height:38px; border-radius:11px; background:linear-gradient(135deg,#6366f1,#22d3ee);
  color:#fff; font-weight:700; font-size:17px; display:flex; align-items:center; justify-content:center; }
.title { font-size:19px; font-weight:700; letter-spacing:-.01em; }
.sub { font-size:12px; color:#64748b; }
.badge { font-family:"ZTS Mono"; font-size:11px; letter-spacing:.04em; text-transform:uppercase;
  padding:5px 10px; border-radius:999px; background:#e0e7ff; color:#4338ca; border:1px solid #c7d2fe; }
.card { margin-top:22px; background:#fff; border:1px solid #e2e8f0; border-radius:16px;
  padding:22px 24px; box-shadow:0 10px 30px rgba(15,23,42,.06); }
.counter { display:flex; align-items:center; gap:16px; }
.value { font-family:"ZTS Mono"; font-size:44px; font-weight:400; line-height:1;
  min-width:120px; color:#0f172a; }
button { font-family:"ZTS Sans"; font-size:14px; font-weight:600; padding:9px 16px; border-radius:10px;
  border:1px solid #cbd5e1; background:#fff; color:#0f172a; cursor:pointer; }
button.primary { background:#4f46e5; border-color:#4338ca; color:#fff; }
.features { margin:20px 0 0; padding:0; list-style:none; display:grid; grid-template-columns:1fr 1fr 1fr;
  gap:12px; }
.features li { background:#f8fafc; border:1px solid #e2e8f0; border-radius:12px; padding:12px 14px;
  font-size:13px; color:#334155; }
.features b { display:block; font-size:13px; color:#0f172a; margin-bottom:2px; }
.meta { margin-top:18px; display:flex; align-items:center; justify-content:space-between;
  font-family:"ZTS Mono"; font-size:12px; color:#64748b; }
.tag { color:#0f766e; }
</style>
