#!/bin/bash
# 고장 내기 — VPC·서브넷·인바운드 없는 보안 그룹 web·인스턴스(8080 nginx)를 만들고 nginx 가 뜰 때까지 기다린다.
# Floci 는 보안 그룹을 네트워크로 강제하지 않으므로 인스턴스에는 컨테이너 이름으로 바로 닿는다 — 기다림은 그걸로 한다.
set -euo pipefail

vpc=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --query Vpc.VpcId --output text)
subnet=$(aws ec2 create-subnet --vpc-id "$vpc" --cidr-block 10.0.1.0/24 --query Subnet.SubnetId --output text)
sg=$(aws ec2 create-security-group --group-name web --description web --vpc-id "$vpc" --query GroupId --output text)

cat > /tmp/user-data.sh <<'USERDATA'
#!/bin/bash
yum install -y nginx
sed -i 's/listen       80;/listen       8080;/; s/listen       \[::\]:80;/listen       [::]:8080;/' /etc/nginx/nginx.conf
echo "<h1>hello from ec2</h1>" > /usr/share/nginx/html/index.html
nginx
USERDATA

id=$(aws ec2 run-instances --image-id ami-0abcdef1234567891 --instance-type t3.micro \
  --subnet-id "$subnet" --security-group-ids "$sg" --user-data file:///tmp/user-data.sh \
  --query 'Instances[0].InstanceId' --output text)
echo "instance $id"

# nginx 설치(yum, 약 30~40초)가 끝날 때까지 — 학생이 준비 직후 「원래 안 뜨는 것 아닌가」로 헷갈리지 않게.
for i in $(seq 1 40); do
  if curl -sf -m 3 "http://floci-aws-ec2-$id:8080/" > /dev/null; then
    echo "nginx 응답 (${i}번째 확인)"
    rm -f /tmp/user-data.sh
    exit 0
  fi
  sleep 5
done
echo "nginx 가 200초 안에 뜨지 않았다" >&2
exit 1
