#!/bin/bash
# 고장 내기 — Deployment web(레플리카 0)과 Service web(셀렉터가 파드 라벨과 다르다)을 만든다.
# Deployment 의 UID 를 홈 볼륨에 남겨 둔다 — check-web-kept.sh 가 「지우고 다시 만들지 않았다」를 UID 로 판정한다.
set -euo pipefail

kubectl wait --for=condition=Ready nodes --all --timeout=90s

kubectl apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 0
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  selector:
    app: web-old
  ports:
    - port: 80
      targetPort: 80
YAML

mkdir -p ~/.infralab/k8s-web-down
kubectl get deploy web -o jsonpath='{.metadata.uid}' > ~/.infralab/k8s-web-down/web.uid
echo "web uid: $(cat ~/.infralab/k8s-web-down/web.uid)"
