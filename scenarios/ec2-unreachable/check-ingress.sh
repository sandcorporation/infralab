#!/bin/bash
# default 가 아닌 모든 보안 그룹의 인바운드 규칙이 TCP 8080 하나뿐인지 본다. 어긋난 규칙을 출력한다.
set -uo pipefail

bad=$(aws ec2 describe-security-groups --query 'SecurityGroups[?GroupName!=`default`]' --output json |
  jq -r '.[] | .GroupId as $g | .IpPermissions[]
         | select(.IpProtocol != "tcp" or .FromPort != 8080 or .ToPort != 8080)
         | "\($g): \(.IpProtocol) \(.FromPort // "all")-\(.ToPort // "all")"')
if [ -n "$bad" ]; then
  echo "8080 외의 인바운드 규칙이 열려 있다:" >&2
  echo "$bad" >&2
  exit 1
fi
echo "인바운드는 TCP 8080 뿐"
