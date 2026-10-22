# 학생이 브라우저 터미널로 들어가는 작업용 컨테이너 — awscli·kubectl·terraform 이 미리 들어 있다.
FROM hashicorp/terraform:latest AS tf

FROM alpine:3.21
RUN apk add --no-cache bash aws-cli curl jq ca-certificates vim git
COPY --from=tf /bin/terraform /usr/local/bin/terraform
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl
RUN printf 'export PS1="\\[\\e[32m\\]lab\\[\\e[0m\\]:\\w\\$ "\nalias k=kubectl\n' > /etc/profile.d/lab.sh
WORKDIR /work
CMD ["sleep", "infinity"]
