import { bootstrapApplication } from '@angular/platform-browser';
import { Component, signal } from '@angular/core';

@Component({
  selector: 'zts-root',
  template: `
    <div class="shell">
      <header class="head">
        <div class="brand">
          <div class="logo">ZT</div>
          <div>
            <div class="title">Z-Ts × Angular</div>
            <div class="sub">Zig / WebView / Angular 22</div>
          </div>
        </div>
        <div class="badge">Angular 22</div>
      </header>
      <section class="card">
        <div class="counter">
          <div class="value" data-zts="count">{{ count() }}</div>
          <button (click)="dec()" data-zts="dec">−</button>
          <button class="primary" (click)="inc()" data-zts="inc">＋</button>
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
      <div class="zigbar" data-zts="zig-panel">
  <span class="zigbadge" data-zts="zig-state">ZIG OFFLINE</span>
  <code class="zigseal" data-zts="zig-seal">—</code>
  <span class="zigcount" data-zts="zig-count">—</span>
  <button class="zigbtn" data-zts="zig-inc" disabled>＋</button>
  <button class="zigbtn" data-zts="zig-dec" disabled>−</button>
  <span class="zighint" data-zts="zig-hint">Zig が必要 / Zig required</span>
</div>
      </section>
    </div>
  `,
})
export class App {
  count = signal(0);
  inc() { this.count.update((v) => v + 1); }
  dec() { this.count.update((v) => v - 1); }
  ngAfterViewInit() {
    {
  const zig = window.__ZTS_ZIG__;
  if (zig && typeof zig.mount === "function") { zig.mount(); }
  else { const zts = window.__ztsPostMessage; if (zts) zts(JSON.stringify({ app: "ready" })); }
}
  }
}
bootstrapApplication(App);
