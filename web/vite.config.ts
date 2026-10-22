import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// /api 는 개발 서버가 backend 로 넘긴다 — 브라우저는 한 오리진만 본다(CORS 없음).
// compose 안에서는 INFRALAB_API_PROXY=http://backend:8000, 호스트에서 직접 돌리면 기본값.
// compose 안에서는 Windows 호스트의 바인드 마운트가 파일 변경 이벤트를 전하지 못해 Vite 가 옛 모듈을 계속
// 내준다 — 그때는 폴링으로 감시한다(INFRALAB_API_PROXY 가 compose 에서만 설정된다).
const inCompose = Boolean(process.env.INFRALAB_API_PROXY);

export default defineConfig({
  plugins: [react()],
  server: {
    watch: inCompose ? { usePolling: true, interval: 500 } : undefined,
    proxy: {
      "/api": {
        target: process.env.INFRALAB_API_PROXY ?? "http://127.0.0.1:58040",
        changeOrigin: true,
      },
    },
  },
});
