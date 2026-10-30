import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], build: { assetsInlineLimit: 1e9, cssCodeSplit: false } });
