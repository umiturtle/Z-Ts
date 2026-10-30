import { createSignal, createEffect } from 'solid-js';
import { render } from 'solid-js/web';

function App() {
  const [count, setCount] = createSignal(0);
  createEffect(() => {
    document.querySelector('[data-zts="status"]').textContent = 'mounted';
    const zts = window.__ztsPostMessage; if (zts) zts(JSON.stringify({ app: "ready" }));
  });
  return (
    <div class="shell">
      <header class="head">
        <div class="brand">
          <div class="logo">ZT</div>
          <div>
            <div class="title">Z-Ts × Solid</div>
            <div class="sub">Zig / WebView / Solid 1.9</div>
          </div>
        </div>
        <div class="badge">Solid 1.9</div>
      </header>
      <section class="card">
        <div class="counter">
          <div class="value" data-zts="count">{count}</div>
          <button onClick={() => setCount(count - 1)} data-zts="dec">−</button>
          <button className="primary" onClick={() => setCount(count + 1)} data-zts="inc">＋</button>
        </div>
        <ul class="features">
          <li><b>同じ HTML</b>3 OS で同一の画素</li>
          <li><b>同じフォント</b>同梱 woff2 のみ</li>
          <li><b>同じ寸法</b>760×520 固定</li>
        </ul>
        <div class="meta">
          <span data-zts="status">mounted</span>
          <span className="tag">tauri://localhost</span>
        </div>
      </section>
    </div>
  );
}
render(() => <App />, document.getElementById('root'));
