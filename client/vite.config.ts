import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import { fileURLToPath, URL } from 'node:url';

/**
 * Vite config for the Sutando frontend.
 *
 * Build output → `client/dist/`, served by src/web-server.ts at `/` (the
 * primary route after PR-C step 5) with a `/v2` alias for older bookmarks
 * and a `/legacy` fallback that still ships the inline HTML for one
 * release.
 *
 * `base: './'` keeps asset URLs relative so the same bundle works from any
 * server route (`/v2/`, `/`, or eventually a CDN) without rebuilding. Critical
 * for the desktop WKWebView, remote browser (Tailscale / EC2), and the future
 * mobile thin-client wrapper.
 */
export default defineConfig({
  base: './',
  plugins: [react(), tailwindcss()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
    assetsInlineLimit: 4096,
  },
  server: {
    port: 5173,
    strictPort: true,
  },
});
