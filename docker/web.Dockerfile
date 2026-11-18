# syntax=docker/dockerfile:1
# 운영 web 이미지 — Vite 빌드 산출물을 nginx 가 내고 /api 는 backend 로 넘긴다. ghcr.io/sandcorporation/infralab-web:<sha>
# GitHub Actions(image.yml)가 linux/arm64 실행기에서 네이티브로 굽는다. 로컬(amd64)에서도 그대로 빌드된다.
# 빌드 맥락은 web/ 이다.

FROM node:26.13.1-alpine@sha256:6bd9ab43c0ec0190ca7b2d193906cb8b7edf6e7f4afa43ddeccd6452710bffb5 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . ./
RUN npm run build

FROM nginx:1.31.0-alpine@sha256:2f07d83bf561b506400dc183b1b2003803e39efbd22451f848adaba14d28c7c7 AS runtime
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
