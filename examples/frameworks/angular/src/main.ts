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
      </section>
    </div>
  `,
})
export class App {
  count = signal(0);
  inc() { this.count.update((v) => v + 1); }
  dec() { this.count.update((v) => v - 1); }
  ngAfterViewInit() {
    const zts = window.__ztsPostMessage; if (zts) zts(JSON.stringify({ app: "ready" }));
  }
}
bootstrapApplication(App);
