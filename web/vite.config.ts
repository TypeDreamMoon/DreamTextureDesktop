import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import { fileURLToPath, URL } from 'node:url'

// 构建产物在 web/dist。后端（DreamTexture 仓库）把它当作提交进仓库的界面嵌进 exe：
// 后端的 tools/sync-web-ui.ps1 从这里构建、拷进它的 internal/web/dist；
// 本仓库打桌面安装包时也是先构建到这里，再拷进 backend/ 子模块编 sidecar。
export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  build: {
    outDir: 'dist',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    // 开发期前端独立跑，接口与 WebSocket 都代理到后端。
    proxy: {
      '/api': {
        target: 'http://127.0.0.1:8777',
        changeOrigin: true,
        ws: true,
      },
    },
  },
})
