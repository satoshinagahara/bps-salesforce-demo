import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  server: {
    port: 5173,
    proxy: {
      '/chat': {
        target: 'http://localhost:8000',
        configure: (proxy) => {
          // SSE のバッファリング防止:
          // Vite dev server の圧縮ミドルウェアがレスポンスを
          // バッファしてから gzip するため SSE が届かない。
          // Accept-Encoding を除去して圧縮を無効化する。
          proxy.on('proxyReq', (proxyReq) => {
            proxyReq.removeHeader('Accept-Encoding')
          })
        },
      },
      '/health': 'http://localhost:8000',
      '/profile': 'http://localhost:8000',
    },
  },
})
