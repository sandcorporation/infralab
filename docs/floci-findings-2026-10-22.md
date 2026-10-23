# Floci 실측 (2026-10-22, floci/floci 2.3.0)

시나리오를 만들며 확인한 것. 안 되는 것은 YAML 주석이 아니라 여기 남긴다.

## S3

- `aws s3 mb`, `s3api put-bucket-versioning / get-bucket-versioning / head-bucket / head-object / put-bucket-website /
  get-bucket-website`, `s3 cp` 모두 aws cli v2 로 동작. 기동 1~2초 뒤 응답.
- 버저닝을 켠 버킷은 `aws s3 rb --force` 로 지워지지 않는다(BucketNotEmpty, 버전이 남는다). 상태 비우기는
  컨테이너 재생성(에이전트 `/api/floci/reset`)이 맞다.

## EC2

- 인스턴스는 실제 컨테이너 `floci-aws-ec2-<instance-id>` 로 뜬다. 네트워크는 `bridge` + VPC 네트워크
  (`floci-aws-vpc-…-<vpc-id>`, 사설 IP 10.0.x.x) + **Floci 가 붙은 `infralab` 네트워크**. 그래서 workstation 에서
  **컨테이너 이름으로 닿는다**(`curl http://floci-aws-ec2-<id>:8080/`). VPC 사설 IP(10.0.1.x)로는 닿지 않는다 —
  workstation 이 그 네트워크에 없다.
- AMI 는 `aws ec2 describe-images` 가 주는 고정 목록(`ami-0abcdef1234567891` = al2023, `ami-ubuntu2204`,
  `ami-debian12`, `ami-alpine` …). 없는 AMI 를 줘도 인스턴스가 뜬다(Amazon Linux). 실제 이미지는 AL2023 계열로
  `python3`·`yum`·`dnf`·`curl` 이 있고 **인터넷이 된다**(`yum install -y nginx` 약 30초).
- **user-data 는 셸 스크립트로 실행된다**(`UserDataPipeline`, `/var/lib/user-data.sh`). 성공·실패가 Floci 로그에
  남는다. `systemctl` 은 없다(PID 1 이 systemd 가 아니다) — 데몬은 직접 띄운다(`nginx`).
- **인스턴스 안의 80 포트는 쓸 수 없다.** Floci 의 메타데이터 서비스 socat 이 `169.254.169.254:80` 에 묶여 있어
  `0.0.0.0:80` 바인드가 `Address already in use` 로 실패한다(nginx, python http.server 둘 다). **8080** 등
  다른 포트로 연다. 시나리오 설명과 user-data 예시가 8080 을 쓴다.
- 보안 그룹 인바운드를 열면 포트마다 포워더 컨테이너 `floci-aws-ec2-fwd-<id>-<port>` 가 생겨 호스트 포트
  30001… 로 공개한다(socat → 인스턴스). 검사는 이걸 쓰지 않는다 — 컨테이너 이름으로 직접 간다.
- **보안 그룹은 네트워크로 강제되지 않는다**(2026-10-23 실측). 인바운드가 하나도 없는 보안 그룹의 인스턴스에도 workstation 에서
  `floci-aws-ec2-<id>:8080` 이 응답한다. 그래서 `ec2-unreachable` 의 「닿는다」는 인스턴스에 붙은 보안 그룹의 인바운드(0.0.0.0/0 에서
  TCP 8080)와 8080 응답을 **둘 다** 본다(`reach-check.sh`). 인스턴스의 nginx 는 user-data 로 설치되어 약 40초 뒤에 응답한다.
- `describe-security-groups --group-names` 대신 `--filters Name=group-name,Values=…` 를 쓴다(기본 VPC 가 아니다).

## Terraform

- `hashicorp/aws ~> 5.0` provider 가 Floci 에 붙는다: `endpoints { s3 = "http://infralab-floci:4566" … }`,
  `s3_use_path_style = true`, `skip_credentials_validation / skip_metadata_api_check / skip_requesting_account_id`.
  `terraform init` 약 23초(provider 다운로드, workstation 에 인터넷 필요), `apply` 로 `aws_s3_bucket` +
  `aws_s3_bucket_versioning` 생성·`destroy` 확인. `terraform.tfstate` 는 작업 폴더에 남는다.
- 그래서 Terraform 시나리오는 **terraform-s3** 로 간다. kubernetes provider → kind 는 실측하지 않았다(S3 쪽이
  되므로 택할 이유가 없었다).

## 확인하지 않은 것

- RDS, Lambda. EC2 의 ARM AMI. user-data 가 cloud-init 문법(`#cloud-config`)도 받는지.
