#!/bin/bash
# Deployment web 이 환경 준비 때 만든 그것인지 UID 로 본다 — 지우고 같은 이름으로 다시 만들면 UID 가 바뀐다.
want=$(cat ~/.infralab/k8s-web-down/web.uid 2>/dev/null || true)
if [ -z "$want" ]; then
  echo "환경 준비 기록이 없다" >&2
  exit 1
fi
have=$(kubectl get deploy web -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
if [ "$have" != "$want" ]; then
  echo "Deployment web 이 환경 준비 때의 것이 아니다 (지우고 다시 만들었다)" >&2
  exit 1
fi
echo "Deployment web 유지"
