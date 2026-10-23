#!/bin/bash
# 「닿는다」 = 실행 중 인스턴스에 붙은 보안 그룹 중 하나가 TCP 8080 을 0.0.0.0/0 에 열고 있고, 8080 이 응답한다.
# Floci 는 보안 그룹을 네트워크로 강제하지 않아 응답만으로는 닫힌 상태를 구분하지 못한다.
set -uo pipefail

ids=$(aws ec2 describe-instances --filters Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].SecurityGroups[].GroupId' --output text)
if [ -z "$ids" ]; then
  echo "실행 중인 인스턴스가 없다" >&2
  exit 1
fi
open=0
for sg in $ids; do
  n=$(aws ec2 describe-security-groups --group-ids "$sg" --output json |
    jq '[.SecurityGroups[].IpPermissions[]
         | select((.IpProtocol == "tcp" or .IpProtocol == "-1")
                  and ((.FromPort == null) or (.FromPort <= 8080 and .ToPort >= 8080))
                  and ([.IpRanges[].CidrIp] | index("0.0.0.0/0")))] | length')
  if [ "${n:-0}" -gt 0 ]; then open=1; fi
done
if [ "$open" -ne 1 ]; then
  echo "인스턴스의 보안 그룹($ids)이 0.0.0.0/0 에서 오는 TCP 8080 을 허용하지 않는다" >&2
  exit 1
fi
exec web-check.sh
