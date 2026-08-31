import { fileURLToPath, URL } from 'node:url'

import vue from '@vitejs/plugin-vue'
import { defineConfig } from 'vite'

// The app always calls the API at a relative `/v1/...` path, never at an
// absolute URL. In the deployed shape that is literally true -- one CloudFront
// distribution serves the static bundle from S3 and forwards /v1/* to the ALB,
// so every request is same-origin and no CORS preflight ever happens.
//
// The dev server has to reproduce that, or `npm run dev` would be exercising a
// different network shape from production: cross-origin, preflighted, and
// needing CORS_ORIGINS set on the backend. A proxy keeps the one code path.
const apiTarget = process.env.AWUCA_API_URL ?? 'http://localhost:8080'

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5173,
    proxy: {
      '/v1': { target: apiTarget, changeOrigin: true },
      '/healthz': { target: apiTarget, changeOrigin: true },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
})
