import { defineConfig } from 'vite';
import solid from 'vite-plugin-solid';
export default defineConfig({ plugins: [solid()], build: { assetsInlineLimit: 1e9, cssCodeSplit: false } });
