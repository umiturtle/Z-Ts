#!/usr/bin/env node
// 9 つのフレームワーク（React / Solid / Svelte / Angular / Next.js / Nuxt / Astro /
// SvelteKit / SolidStart）で **同じ 1 画面** を作り、その静的出力を
// `examples/gallery/src/web/fw-<name>.html`（単一ファイル）へ inline する開発用スクリプト。
//
// - 生成物はコミットする（CI は npm install をしない＝毎チャットのコールドスタートを守る）。
// - ネットワーク（registry.npmjs.org）と npm が必要。再生成は
//     node scripts/gen-framework-demos.mjs [name ...]
// - 各デモは「フレームワーク名・バージョン・カウンタ・機能リスト」を同じ DOM 構造で出し、
//   描画後に `{"app":"ready"}` を `__ztsPostMessage` へ送る。ギャラリーはこれを待って撮影する。
//
// スクリーンショットの OS 間比較を成立させるため、**システムフォントを一切使わない**
// （`ZTS Sans` / `ZTS Mono` はギャラリーが同一の woff2 を配信する）。

import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, extname, join, relative, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const FW_ROOT = join(ROOT, 'examples', 'frameworks');
const WEB_DIR = join(ROOT, 'examples', 'gallery', 'src', 'web');

const V = {
  vite: '^8.3.5',
  react: '^19.3.1',
  reactDom: '^19.3.1',
  vitePluginReact: '^6.1.2',
  solid: '^1.9.17',
  vitePluginSolid: '^2.11.14',
  svelte: '^5.57.3',
  vitePluginSvelte: '^7.3.1',
  svelteKit: '^3.1.0',
  adapterStatic: '^4.0.0',
  angularCli: '^22.2.4',
  angularCore: '^22.2.3',
  next: '^16.4.3',
  astro: '^6.4.8',
  nuxt: '^4.6.3',
  solidStart: '^2.1.0',
  solidRouter: '>=0.16.0 <2.0.0-0',
};

// ---------------------------------------------------------------- shared UI

const APP_CSS = `/* Z-Ts framework demo — 3 OS で同一画素にするためシステムフォントを使わない。 */
@font-face { font-family:ZTSSans; font-style:normal; font-weight:400; font-display:block;
  src:url("/zts/fonts/zts-sans-400.woff2") format("woff2"); }
@font-face { font-family:ZTSSans; font-style:normal; font-weight:700; font-display:block;
  src:url("/zts/fonts/zts-sans-700.woff2") format("woff2"); }
@font-face { font-family:ZTSMono; font-style:normal; font-weight:400; font-display:block;
  src:url("/zts/fonts/zts-mono-400.woff2") format("woff2"); }
* { box-sizing:border-box; }
html,body { margin:0; padding:0; height:100%; }
body { font-family:ZTSSans; font-size:15px; line-height:24px; color:#0f172a; background:#f4f6fb;
  -webkit-font-smoothing:antialiased; text-rendering:geometricPrecision; font-kerning:normal;
  font-synthesis:none; }
.shell { width:760px; margin:0 auto; padding:28px 32px 32px; }
.head { display:flex; align-items:center; justify-content:space-between; }
.brand { display:flex; align-items:center; gap:12px; flex:0 0 auto; }
.logo { width:38px; height:38px; border-radius:11px; background:linear-gradient(135deg,#6366f1,#22d3ee);
  color:#fff; font-weight:700; font-size:17px; display:flex; align-items:center; justify-content:center; }
.title { font-size:19px; font-weight:700; letter-spacing:-.01em; }
.sub { font-size:12px; color:#64748b; }
.badge { flex:0 0 auto; font-family:ZTSMono; font-size:11px; letter-spacing:.04em; text-transform:uppercase;
  padding:5px 10px; border-radius:999px; background:#e0e7ff; color:#4338ca; border:1px solid #c7d2fe; }
.card { margin-top:22px; background:#fff; border:1px solid #e2e8f0; border-radius:16px;
  padding:22px 24px; box-shadow:0 10px 30px rgba(15,23,42,.06); }
.counter { display:flex; align-items:center; gap:16px; }
.value { font-family:ZTSMono; font-size:44px; font-weight:400; line-height:1;
  min-width:120px; color:#0f172a; }
button { font-family:ZTSSans; font-size:14px; font-weight:600; padding:9px 16px; border-radius:10px;
  border:1px solid #cbd5e1; background:#fff; color:#0f172a; cursor:pointer; }
button.primary { background:#4f46e5; border-color:#4338ca; color:#fff; }
.features { margin:20px 0 0; padding:0; list-style:none; display:grid; grid-template-columns:1fr 1fr 1fr;
  gap:12px; }
.features li { background:#f8fafc; border:1px solid #e2e8f0; border-radius:12px; padding:12px 14px;
  font-size:13px; color:#334155; }
.features b { display:block; font-size:13px; color:#0f172a; margin-bottom:2px; }
.meta { margin-top:18px; display:flex; align-items:center; justify-content:space-between;
  font-family:ZTSMono; font-size:12px; color:#64748b; }
.tag { color:#0f766e; }
`;

const HTML_SHELL = (body, script) => `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Z-Ts — framework demo</title>
<style>${APP_CSS}</style>
</head>
<body>
${body}
${script}
</body>
</html>
`;

// The DOM every framework renders. Only the framework label/version differs.
const appBody = (label, version) => `<div class="shell">
  <header class="head">
    <div class="brand">
      <div class="logo">ZT</div>
      <div>
        <div class="title">Z-Ts × ${label}</div>
        <div class="sub">Zig 製 WebView で動く ${label} ${version} の静的ビルド</div>
      </div>
    </div>
    <div class="badge">${label} ${version}</div>
  </header>
  <section class="card">
    <div class="counter">
      <div class="value" data-zts="count">0</div>
      <button data-zts="dec">−</button>
      <button class="primary" data-zts="inc">＋</button>
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
</div>`;

const READY_JS = `const zts = window.__ztsPostMessage; if (zts) zts(JSON.stringify({ app: "ready" }));`;

// ---------------------------------------------------------------- per app
//
// Each entry writes a real project and knows how to build it. `dist` is the directory of the
// static output; the inliner turns it into one self-contained HTML file.

const APPS = {
  react: {
    label: 'React',
    version: V.react,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-react',
        private: true,
        type: 'module',
        scripts: { build: 'vite build' },
        dependencies: { react: V.react, 'react-dom': V.reactDom },
        devDependencies: { vite: V.vite, '@vitejs/plugin-react': V.vitePluginReact },
      });
      write(join(dir, 'vite.config.mjs'), `import { defineConfig } from 'vite';\nimport react from '@vitejs/plugin-react';\nexport default defineConfig({ plugins: [react()], build: { assetsInlineLimit: 1e9, cssCodeSplit: false } });\n`);
      write(join(dir, 'index.html'), HTML_SHELL('<div id="root"></div>', '<script type="module" src="/src/main.jsx"></script>'));
      write(join(dir, 'src/main.jsx'), `import { createRoot } from 'react-dom/client';
import { useEffect, useState } from 'react';

function App() {
  const [count, setCount] = useState(0);
  useEffect(() => {
    document.querySelector('[data-zts="status"]').textContent = 'mounted';
    ${READY_JS}
  }, []);
  return (
    ${reactBody('React', '19')}
  );
}
createRoot(document.getElementById('root')).render(<App />);
`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'dist',
  },

  solid: {
    label: 'Solid',
    version: V.solid,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-solid',
        private: true,
        type: 'module',
        scripts: { build: 'vite build' },
        dependencies: { 'solid-js': V.solid },
        devDependencies: { vite: V.vite, 'vite-plugin-solid': V.vitePluginSolid },
      });
      write(join(dir, 'vite.config.mjs'), `import { defineConfig } from 'vite';\nimport solid from 'vite-plugin-solid';\nexport default defineConfig({ plugins: [solid()], build: { assetsInlineLimit: 1e9, cssCodeSplit: false } });\n`);
      write(join(dir, 'index.html'), HTML_SHELL('<div id="root"></div>', '<script type="module" src="/src/main.jsx"></script>'));
      write(join(dir, 'src/main.jsx'), `import { createSignal, createEffect } from 'solid-js';
import { render } from 'solid-js/web';

function App() {
  const [count, setCount] = createSignal(0);
  createEffect(() => {
    document.querySelector('[data-zts="status"]').textContent = 'mounted';
    ${READY_JS}
  });
  return (
    ${jsxBody('Solid', '1.9')}
  );
}
render(() => <App />, document.getElementById('root'));
`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'dist',
  },

  svelte: {
    label: 'Svelte',
    version: V.svelte,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-svelte',
        private: true,
        type: 'module',
        scripts: { build: 'vite build' },
        dependencies: { svelte: V.svelte },
        devDependencies: { vite: V.vite, '@sveltejs/vite-plugin-svelte': V.vitePluginSvelte },
      });
      write(join(dir, 'vite.config.mjs'), `import { defineConfig } from 'vite';\nimport { svelte } from '@sveltejs/vite-plugin-svelte';\nexport default defineConfig({ plugins: [svelte()], build: { assetsInlineLimit: 1e9, cssCodeSplit: false } });\n`);
      write(join(dir, 'svelte.config.js'), `export default { compilerOptions: { hydratable: false } };\n`);
      write(join(dir, 'index.html'), HTML_SHELL('<div id="root"></div>', '<script type="module" src="/src/main.js"></script>'));
      write(join(dir, 'src/App.svelte'), svelteBody('Svelte', '5.57'));
      write(join(dir, 'src/main.js'), `import { mount } from 'svelte';\nimport App from './App.svelte';\nmount(App, { target: document.getElementById('root') });\n`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'dist',
  },

  angular: {
    label: 'Angular',
    version: V.angularCore,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-angular',
        private: true,
        scripts: { build: 'ng build' },
        dependencies: {
          '@angular/common': V.angularCore,
          '@angular/compiler': V.angularCore,
          '@angular/core': V.angularCore,
          '@angular/platform-browser': V.angularCore,
          rxjs: '^7.8.2',
          tslib: '^2.8.1',
          
        },
        devDependencies: { '@angular/build': V.angularCli, '@angular/cli': V.angularCli, '@angular/compiler-cli': V.angularCore, typescript: '>=6.0 <6.1' },
      });
      writeJson(join(dir, 'angular.json'), {
        version: 1,
        projects: {
          demo: {
            projectType: 'application',
            root: '',
            sourceRoot: 'src',
            architect: {
              build: {
                builder: '@angular/build:application',
                options: {
                  browser: 'src/main.ts',
                  index: 'src/index.html',
                  tsConfig: 'tsconfig.json',
                  outputPath: 'dist',
                  inlineStyleLanguage: 'css',
                  assets: [],
                  styles: [],
                },
                configurations: { production: { optimization: false, sourceMap: false, outputHashing: 'none' }, development: {} },
                defaultConfiguration: 'production',
              },
            },
          },
        },
      });
      writeJson(join(dir, 'tsconfig.json'), {
        compileOnSave: false,
        compilerOptions: {
          strict: true,
          target: 'ES2022',
          module: 'ES2022',
          moduleResolution: 'bundler',
          experimentalDecorators: true,
          skipLibCheck: true,
          lib: ['ES2022', 'dom'],
        },
        angularCompilerOptions: { strictTemplates: true },
        include: ['src/**/*.ts', 'types/**/*.d.ts'],
      });
      writeGlobalTypes(dir);
      write(join(dir, 'src/index.html'), `<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Z-Ts — framework demo</title>
<style>${APP_CSS}</style>
</head>
<body>
<zts-root></zts-root>
</body>
</html>
`);
      write(join(dir, 'src/main.ts'), `import { bootstrapApplication } from '@angular/platform-browser';
import { Component, signal } from '@angular/core';

@Component({
  selector: 'zts-root',
  template: \`
${angularBody('Angular', '22')}
  \`,
})
export class App {
  count = signal(0);
  inc() { this.count.update((v) => v + 1); }
  dec() { this.count.update((v) => v - 1); }
  ngAfterViewInit() {
    ${READY_JS}
  }
}
bootstrapApplication(App);
`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npx', ['ng', 'build']],
    dist: 'dist/browser',
  },

  next: {
    label: 'Next.js',
    version: V.next,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-next',
        private: true,
        scripts: { build: 'next build' },
        dependencies: { next: V.next, react: V.react, 'react-dom': V.reactDom },
        devDependencies: { typescript: '>=6.0 <6.1', '@types/react': '^19.3.0', '@types/react-dom': '^19.3.0' },
      });
      write(join(dir, 'next.config.mjs'), `export default { output: 'export', images: { unoptimized: true }, trailingSlash: true, reactStrictMode: true };\n`);
      writeJson(join(dir, 'tsconfig.json'), {
        compilerOptions: { target: 'ES2022', lib: ['dom', 'dom.iterable', 'esnext'], strict: true, noEmit: true, esModuleInterop: true, module: 'esnext', moduleResolution: 'bundler', jsx: 'preserve', skipLibCheck: true, plugins: [{ name: 'next' }] },
        include: ['**/*.ts', '**/*.tsx'],
        exclude: ['node_modules'],
      });
      write(join(dir, 'app/layout.tsx'), `import './globals.css';
export const metadata = { title: 'Z-Ts — framework demo' };
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (<html lang="ja"><body>{children}</body></html>);
}
`);
      write(join(dir, 'app/globals.css'), APP_CSS);
      writeGlobalTypes(dir);
      write(join(dir, 'app/page.tsx'), `'use client';
import { useEffect, useState } from 'react';

export default function Page() {
  const [count, setCount] = useState(0);
  useEffect(() => {
    document.querySelector('[data-zts="status"]')!.textContent = 'mounted';
    ${READY_JS}
  }, []);
  return (
    ${reactBody('Next.js', '16')}
  );
}
`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'out',
  },

  nuxt: {
    label: 'Nuxt',
    version: V.nuxt,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-nuxt',
        private: true,
        type: 'module',
        scripts: { build: 'nuxt generate' },
        dependencies: { nuxt: V.nuxt },
      });
      write(join(dir, 'nuxt.config.ts'), `export default defineNuxtConfig({
  ssr: true,
  telemetry: false,
  app: { head: { title: 'Z-Ts — framework demo' } },
  nitro: { preset: 'static' },
});
`);
      write(join(dir, 'app.vue'), `<template>
${vueBody('Nuxt', '4.6')}
</template>
<script setup lang="ts">
import { ref, onMounted } from 'vue';
const count = ref(0);
onMounted(() => {
  if (import.meta.client) {
    document.querySelector('[data-zts="status"]')!.textContent = 'mounted';
    ${READY_JS}
  }
});
</script>
<style>${APP_CSS}</style>
`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: '.output/public',
  },

  astro: {
    label: 'Astro',
    version: V.astro,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-astro',
        private: true,
        type: 'module',
        scripts: { build: 'astro build' },
        dependencies: { astro: V.astro },
      });
      write(join(dir, 'astro.config.mjs'), `import { defineConfig } from 'astro/config';\nexport default defineConfig({ build: { inlineStylesheets: 'always' } });\n`);
      write(join(dir, 'src/pages/index.astro'), `---
const label = 'Astro';
const version = '6.4';
---
<html lang="ja">
<head><meta charset="utf-8"><title>Z-Ts — framework demo</title><style is:global>${APP_CSS}</style></head>
<body>
${astroBody('Astro', '6.4')}
<script>
  document.querySelector('[data-zts="status"]').textContent = 'mounted';
  ${READY_JS}
</script>
</body>
</html>
`);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'dist',
  },

  sveltekit: {
    label: 'SvelteKit',
    version: V.svelteKit,
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-sveltekit',
        private: true,
        type: 'module',
        scripts: { build: 'vite build' },
        dependencies: { '@sveltejs/kit': V.svelteKit, svelte: V.svelte },
        devDependencies: { vite: V.vite, '@sveltejs/adapter-static': V.adapterStatic, '@sveltejs/vite-plugin-svelte': V.vitePluginSvelte },
      });
      // SvelteKit 3 removed `svelte.config.js`: everything lives in the Vite plugin options.
      write(join(dir, 'vite.config.mjs'), `import { defineConfig } from 'vite';
import { sveltekit } from '@sveltejs/kit/vite';
import adapter from '@sveltejs/adapter-static';
export default defineConfig({
  plugins: [sveltekit({ adapter: adapter({ strict: false }), output: { bundleStrategy: 'single' } })],
  build: { assetsInlineLimit: 1e9, cssCodeSplit: false },
});
`);
      write(join(dir, 'src/app.html'), `<!doctype html>\n<html lang="ja">\n<head><meta charset="utf-8">%sveltekit.head%<title>Z-Ts — framework demo</title></head>\n<body data-sveltekit-preload-data="hover"><div style="display:contents">%sveltekit.body%</div></body>\n</html>\n`);
      write(join(dir, 'src/routes/+layout.js'), `export const prerender = true;\nexport const ssr = true;\n`);
      write(join(dir, 'src/routes/+page.js'), `export const prerender = true;\nexport const ssr = true;\n`);
      write(join(dir, 'src/routes/+page.svelte'), svelteKitBody('SvelteKit', '3.1'));
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'build',
  },

  solidstart: {
    label: 'SolidStart',
    version: '2.1',
    files: (dir) => {
      writeJson(join(dir, 'package.json'), {
        name: 'zts-demo-solidstart',
        private: true,
        type: 'module',
        scripts: { build: 'vite build' },
        dependencies: { '@solidjs/router': V.solidRouter, '@solidjs/start': V.solidStart, 'solid-js': V.solid },
        devDependencies: { vite: V.vite },
      });
      // SolidStart 2.x is a Vite plugin; SPA mode (`ssr: false`) emits a self-contained
      // `dist/client/index.html` that the gallery can embed as one file.
      write(join(dir, 'vite.config.mjs'), `import { defineConfig } from 'vite';
import { solidStart } from '@solidjs/start/config';
export default defineConfig({
  plugins: [solidStart({ ssr: false })],
  build: { assetsInlineLimit: 1e9 },
});
`);
      // Single-route demo: rendering the page component directly keeps the SSR output
      // deterministic (the file-router manifest is only needed for multi-route apps).
      write(join(dir, 'src/app.tsx'), `import './app.css';
import Home from './routes/index';

export default function App() {
  return <Home />;
}
`);
      // Custom SPA entry: mount the single page directly. (`StartClient` expects the hydration
      // payload that only exists in the SSR flow, so it renders nothing in `ssr: false` builds.)
      write(join(dir, 'src/entry-client.tsx'), `import './app.css';
import { render } from 'solid-js/web';
import Home from './routes/index';
render(() => <Home />, document.getElementById('app'));
`);
      write(join(dir, 'src/entry-server.tsx'), `import { createHandler, StartServer } from '@solidjs/start/server';
export default createHandler(() => (
  <StartServer
    document={({ assets, children, scripts }) => (
      <html lang="ja">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width,initial-scale=1" />
          <title>Z-Ts — framework demo</title>
          {assets}
        </head>
        <body>
          <div id="app">{children}</div>
          {scripts}
        </body>
      </html>
    )}
  />
));
`);
      write(join(dir, 'src/routes/index.tsx'), `import { createSignal, onMount } from 'solid-js';

export default function Home() {
  const [count, setCount] = createSignal(0);
  onMount(() => {
    document.querySelector('[data-zts="status"]')!.textContent = 'mounted';
    ${READY_JS}
  });
  return (
    ${jsxBody('SolidStart', '2.1')}
  );
}
`);
      write(join(dir, 'src/app.css'), APP_CSS);
      writeGlobalTypes(dir);
    },
    build: ['npm', ['install', '--no-audit', '--no-fund'], 'npm', ['run', 'build']],
    dist: 'dist/client',
    // SolidStart 2 in SPA mode emits only `dist/client/_build` (no shell). The client entry is named
    // in Vite's manifest, so we write the shell ourselves — the app itself is SolidStart's router.
    prerender: (dir, distDir) => {
      // `ssr: false` emits only `dist/client/_build`; the client entry is named in Vite's manifest.
      const manifest = JSON.parse(readFileSync(join(distDir, '.vite/manifest.json'), 'utf8'));
      const entry = Object.values(manifest).find((chunk) => chunk.isEntry && chunk.file.includes('entry-client'));
      if (!entry) throw new Error('no entry-client chunk in the Vite manifest');
      // The build emits the app's CSS as a separate asset; a hand-written shell must link it.
      const css = readdirSync(join(distDir, dirname(entry.file)))
        .filter((name) => name.endsWith('.css'))
        .sort()
        .map((name) => `<link rel="stylesheet" href="./${join(dirname(entry.file), name).split(sep).join('/')}">`)
        .join('\n');
      writeFileSync(
        join(distDir, 'index.html'),
        HTML_SHELL(
          '<div id="app"></div>',
          `${css}\n<script type="module" src="./${entry.file}"></script>`,
        ),
      );
    },
    bestEffort: true,
  },
};

// ---------------------------------------------------------------- templates

function jsxBody(label, version) {
  return `<div class="shell">
      <header class="head">
        <div class="brand">
          <div class="logo">ZT</div>
          <div>
            <div class="title">Z-Ts × ${label}</div>
            <div class="sub">Zig 製 WebView で動く ${label} ${version} の静的ビルド</div>
          </div>
        </div>
        <div class="badge">${label} ${version}</div>
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
    </div>`;
}

// React needs `className`; Solid accepts `class`. Everything else is shared.
function reactBody(label, version) {
  return jsxBody(label, version).replace(/(\s)class=/g, '$1className=');
}

function svelteBody(label, version) {
  return `<script>
  let count = 0;
  import { onMount } from 'svelte';
  onMount(() => {
    document.querySelector('[data-zts="status"]').textContent = 'mounted';
    ${READY_JS}
  });
</script>

<div class="shell">
  <header class="head">
    <div class="brand">
      <div class="logo">ZT</div>
      <div>
        <div class="title">Z-Ts × ${label}</div>
        <div class="sub">Zig 製 WebView で動く ${label} ${version} の静的ビルド</div>
      </div>
    </div>
    <div class="badge">${label} ${version}</div>
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

<style>${APP_CSS}</style>
`;
}

function svelteKitBody(label, version) {
  return svelteBody(label, version).replace(
    "import { onMount } from 'svelte';\n  onMount(() => {",
    "import { onMount } from 'svelte';\n  onMount(() => {\n    if (typeof document === 'undefined') return;",
  );
}

function angularBody(label, version) {
  return `    <div class="shell">
      <header class="head">
        <div class="brand">
          <div class="logo">ZT</div>
          <div>
            <div class="title">Z-Ts × ${label}</div>
            <div class="sub">Zig 製 WebView で動く ${label} ${version} の静的ビルド</div>
          </div>
        </div>
        <div class="badge">${label} ${version}</div>
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
    </div>`;
}

function vueBody(label, version) {
  return `<div class="shell">
  <header class="head">
    <div class="brand">
      <div class="logo">ZT</div>
      <div>
        <div class="title">Z-Ts × ${label}</div>
        <div class="sub">Zig 製 WebView で動く ${label} ${version} の静的ビルド</div>
      </div>
    </div>
    <div class="badge">${label} ${version}</div>
  </header>
  <section class="card">
    <div class="counter">
      <div class="value" data-zts="count">{{ count }}</div>
      <button @click="count--" data-zts="dec">−</button>
      <button class="primary" @click="count++" data-zts="inc">＋</button>
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
</div>`;
}

function astroBody(label, version) {
  return appBody(label, version);
}

// ---------------------------------------------------------------- helpers

function ensureDir(p) {
  mkdirSync(p, { recursive: true });
}

function write(p, text) {
  ensureDir(dirname(p));
  writeFileSync(p, text);
}

// `window.__ztsPostMessage` is injected by every Z-Ts backend (GTK / Cocoa / WebView2); TS
// projects need the declaration to type-check.
function writeGlobalTypes(dir) {
  write(join(dir, 'types/zts-globals.d.ts'), `export {};
declare global {
  interface Window {
    __ztsPostMessage?: (message: string) => void;
  }
}
`);
}

function writeJson(p, value) {
  write(p, JSON.stringify(value, null, 2) + '\n');
}

function sh(cmd, args, cwd, opts = {}) {
  return execFileSync(cmd, args, { cwd, stdio: 'pipe', encoding: 'utf8', ...opts });
}

// ---------------------------------------------------------------- publishing
//
// Each built site is copied to `examples/gallery/src/web/fw/<name>/` and served by the gallery's
// custom scheme exactly like a real Z-Ts app serves its `dist/` over `tauri://`. (Inlining was
// tried first — it breaks as soon as a framework emits more than one ES-module chunk, because
// relative `import "./chunk.js"` cannot resolve from an inline script.)

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8',
  '.map': 'application/json',
};

function publish(name, distDir) {
  const target = join(WEB_DIR, 'fw', name);
  rmSync(target, { recursive: true, force: true });
  ensureDir(target);
  let count = 0;
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const from = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(from);
        continue;
      }
      const rel = relative(distDir, from);
      if (rel.startsWith('..')) continue;
      // Never publish dot-directories (`.vite/manifest.json` is build bookkeeping, and a stale
      // copy of it once ended up `@embedFile`d into the gallery).
      if (rel.split(sep).some((part) => part.startsWith('.'))) continue;
      if (!CONTENT_TYPES[extname(rel)]) continue;  // drop source maps of chunks we never serve
      const to = join(target, rel);
      ensureDir(dirname(to));
      cpSync(from, to);
      count += 1;
    }
  };
  walk(distDir);
  if (!existsSync(join(target, 'index.html'))) throw new Error(`published ${name} without index.html`);
  return count;
}

/// Rewrites `src/fw_assets.zig` from whatever is on disk, so `node scripts/gen-framework-demos.mjs react`
/// does not drop the other frameworks' entries.
function writeAssetTable() {
  const root = join(WEB_DIR, 'fw');
  const files = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else files.push(full);
    }
  };
  walk(root);
  const rows = files.map((file) => {
    const rel = relative(join(ROOT, 'examples', 'gallery', 'src'), file).split(sep).join('/');
    const url = '/fw/' + relative(root, file).split(sep).join('/');
    const mime = CONTENT_TYPES[extname(file)] ?? 'application/octet-stream';
    return `    .{ .path = "${url}", .content_type = "${mime}", .bytes = @embedFile("${rel}") },`;
  });
  const out = `// AUTO-GENERATED by scripts/gen-framework-demos.mjs — do not edit by hand.\n//\n// 9 つのフレームワークの静的ビルド。ギャラリーは \`tauri://localhost/fw/<name>/\` から\n// これをそのまま配信する（本物のアプリが \`dist/\` を配信するのと同じ形）。\n\npub const Asset = struct {\n    path: []const u8,\n    content_type: []const u8,\n    bytes: []const u8,\n};\n\npub const assets = [_]Asset{\n${rows.join('\n')}\n};\n`;
  writeFileSync(join(ROOT, 'examples', 'gallery', 'src', 'fw_assets.zig'), out);
  return rows.length;
}

// ---------------------------------------------------------------- main

const requested = process.argv.slice(2).filter((a) => !a.startsWith('--'));

// `--table-only` regenerates `src/fw_assets.zig` from what is already on disk (no npm, no builds).
if (process.argv.includes('--table-only')) {
  const tableSize = writeAssetTable();
  console.log(`asset table: examples/gallery/src/fw_assets.zig (${tableSize} files)`);
  process.exit(0);
}

const names = requested.length ? requested : Object.keys(APPS);
let failed = [];

for (const name of names) {
  const app = APPS[name];
  if (!app) {
    console.error(`unknown framework: ${name}`);
    process.exitCode = 1;
    continue;
  }
  const dir = join(FW_ROOT, name);
  console.log(`\n=== ${name} (${app.label} ${app.version}) ===`);
  ensureDir(dir);
  app.files(dir);
  writeJson(join(dir, 'zts-demo.json'), { framework: app.label, version: app.version, dist: app.dist });

  const [installCmd, installArgs, buildCmd, buildArgs] = app.build;
  try {
    if (!existsSync(join(dir, 'node_modules'))) {
      console.log(`  install…`);
      sh(installCmd, installArgs, dir);
    }
    console.log(`  build…`);
    sh(buildCmd, buildArgs, dir);
    const distDir = join(dir, app.dist);
    // Frameworks without a static HTML entry (SolidStart SPA) write `index.html` here, next to
    // their client assets, so every relative URL keeps resolving through the custom scheme.
    if (app.prerender) app.prerender(dir, distDir);
    const files = publish(name, distDir);
    console.log(`  -> examples/gallery/src/web/fw/${name}/ (${files} files)`);
  } catch (err) {
    const msg = (err.stderr || err.stdout || err.message || '').toString().trim().split('\n').slice(-6).join('\n');
    console.error(`  FAILED: ${msg}`);
    failed.push(name);
    if (!app.bestEffort) process.exitCode = 1;
  }
}

const tableSize = writeAssetTable();
console.log(`\nasset table: examples/gallery/src/fw_assets.zig (${tableSize} files)`);
console.log('next: run `./zigw fmt examples/gallery/src/fw_assets.zig` and commit the result');
console.log(`done. failed=${failed.length ? failed.join(',') : 'none'}`);
if (failed.length) process.exitCode = 1;
