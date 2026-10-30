import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';
export default defineConfig({ plugins: [svelte()], build: { assetsInlineLimit: 1e9, cssCodeSplit: false } });
