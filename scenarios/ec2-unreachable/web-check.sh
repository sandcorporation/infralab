#!/bin/bash
# 실행 중인 EC2 인스턴스를 찾아 8080 포트에 HTTP 요청을 보낸다. 이 환경에서 인스턴스는 컨테이너이고
# workstation 과 같은 네트워크에 있어 `floci-aws-ec2-<instance-id>` 라는 이름으로 닿는다.
set -euo pipefail
ids=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
if [ -z "$ids" ]; then
  echo "실행 중인 인스턴스가 없다" >&2
  exit 1
fi
for id in $ids; do
  if body=$(curl -sf -m 5 "http://floci-aws-ec2-$id:8080/"); then
    echo "$id → $(echo "$body" | head -c 200)"
    exit 0
  fi
  echo "$id: 8080 응답 없음" >&2
done
exit 1
