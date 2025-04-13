import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// https://vitejs.dev/config/
export default defineConfig({
  plugins: [react()],
  // Remove the PostCSS reference since it's causing issues
  // css: {
  //   postcss: './postcss.config.js'
  // },
  // Enable Vite's built-in CSS optimization
  build: {
    cssMinify: 'lightningcss',
    cssCodeSplit: true,
  },
  server: {
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
        ws: true, // Support WebSockets
      }
    }
  }
});