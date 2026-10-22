import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// /api 는 개발 서버가 backend 로 넘긴다 — 브라우저는 한 오리진만 본다(CORS 없음).
// compose 안에서는 INFRALAB_API_PROXY=http://backend:8000, 호스트에서 직접 돌리면 기본값.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      "/api": {
        target: process.env.INFRALAB_API_PROXY ?? "http://127.0.0.1:58040",
        changeOrigin: true,
      },
    },
  },
});
