'use client';
import { useEffect, useState } from 'react';

export default function Page() {
  const [count, setCount] = useState(0);
  useEffect(() => {
    document.querySelector('[data-zts="status"]')!.textContent = 'mounted';
    {
  const zig = window.__ZTS_ZIG__;
  if (zig && typeof zig.mount === "function") { zig.mount(); }
  else { const zts = window.__ztsPostMessage; if (zts) zts(JSON.stringify({ app: "ready" })); }
}
  }, []);
  return (
    <div className="shell">
      <header className="head">
        <div className="brand">
          <div className="logo">ZT</div>
          <div>
            <div className="title">Z-Ts × Next.js</div>
            <div className="sub">Zig / WebView / Next.js 16</div>
          </div>
        </div>
        <div className="badge">Next.js 16</div>
      </header>
      <section className="card">
        <div className="counter">
          <div className="value" data-zts="count">{count}</div>
          <button onClick={() => setCount(count - 1)} data-zts="dec">−</button>
          <button className="primary" onClick={() => setCount(count + 1)} data-zts="inc">＋</button>
        </div>
        <ul className="features">
          <li><b>同じ HTML</b>3 OS で同一の画素</li>
          <li><b>同じフォント</b>同梱 woff2 のみ</li>
          <li><b>同じ寸法</b>760×520 固定</li>
        </ul>
        <div className="meta">
          <span data-zts="status">mounted</span>
          <span className="tag">tauri://localhost</span>
        </div>
      <div className="zigbar" data-zts="zig-panel">
  <span className="zigbadge" data-zts="zig-state">ZIG OFFLINE</span>
  <code className="zigseal" data-zts="zig-seal">—</code>
  <span className="zigcount" data-zts="zig-count">—</span>
  <button className="zigbtn" data-zts="zig-inc" disabled>＋</button>
  <button className="zigbtn" data-zts="zig-dec" disabled>−</button>
  <span className="zighint" data-zts="zig-hint">Zig が必要 / Zig required</span>
</div>
      </section>
    </div>
  );
}
