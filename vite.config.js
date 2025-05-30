import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import fs from 'fs'; // Import the 'fs' module
import path from 'path'; // Import the 'path' module

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
    host: '0.0.0.0',
    port: 3000,
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
        ws: true, // Support WebSockets
      }
    },
    allowedHosts: [
      'sandbox.ai.uky.edu',
      // Add other allowed hosts here if needed
    ],
//    https: {
//      cert: fs.readFileSync(path.resolve(__dirname, '/var/opt/sectigo-network-agent/ks/sandbox.ai.uky.edu13483066.crt')),
//      key: fs.readFileSync(path.resolve(__dirname, '/var/opt/sectigo-network-agent/ks/sandbox.ai.uky.edu13483066.key')),
//    }
  }
});