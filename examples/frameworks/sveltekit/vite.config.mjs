import { defineConfig } from 'vite';
import { sveltekit } from '@sveltejs/kit/vite';
import adapter from '@sveltejs/adapter-static';
export default defineConfig({
  plugins: [sveltekit({ adapter: adapter({ strict: false }), output: { bundleStrategy: 'single' } })],
  build: { assetsInlineLimit: 1e9, cssCodeSplit: false },
});
