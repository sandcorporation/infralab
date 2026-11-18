# syntax=docker/dockerfile:1
# 운영 web 이미지 — Vite 빌드 산출물을 nginx 가 내고 /api 는 backend 로 넘긴다. ghcr.io/sandcorporation/infralab-web:<sha>
# GitHub Actions(image.yml)가 linux/arm64 실행기에서 네이티브로 굽는다. 로컬(amd64)에서도 그대로 빌드된다.
# 빌드 맥락은 web/ 이다.

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . ./
# 카카오 REST API 키는 브라우저 번들에 들어가는 공개 값이다(비밀 아님). 비우면 화면은 Fake 로그인만 보인다.
ARG VITE_KAKAO_REST_KEY=
ENV VITE_KAKAO_REST_KEY=$VITE_KAKAO_REST_KEY
RUN npm run build

FROM nginx:1.27-alpine AS runtime
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
