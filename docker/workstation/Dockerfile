# 학생이 브라우저 터미널로 들어가는 작업용 컨테이너 — awscli·kubectl·terraform·node·python3·java 25·claude·codex 가 미리 들어 있다.
# docker CLI 는 일부러 넣지 않는다 — docker 부재가 AI 의 호스트 우회 차단의 전부다. Gradle 도 넣지 않는다(프로젝트의 ./gradlew 가 받는다).
FROM hashicorp/terraform:1.17.2@sha256:6e9c1e647c31a960dc9b59e13272f9111d90010c10b717f77ffb324767660475 AS tf

# alpine 3.21 패키지는 openjdk 21 까지다 — 25 는 Temurin 의 musl 빌드를 복사한다.
FROM eclipse-temurin:25.0.5_8-jdk-alpine@sha256:c7c3d0bdf7f2bbc5a05a6712ed334d198360105634ea9adf76fca94f381b1e3f AS jdk

# linux/amd64·arm64 로 게시한다(image.yml, 아키텍처마다 네이티브 실행기).
FROM alpine:3.21.10@sha256:bc21487101ae47172509130ee1092cc273a831968d64b617776d1f69c81e42ab
ARG TARGETARCH
RUN apk add --no-cache bash aws-cli curl jq ca-certificates vim git nodejs npm python3 py3-pip
COPY --from=tf /bin/terraform /usr/local/bin/terraform
RUN curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/${TARGETARCH:-amd64}/kubectl" \
 && chmod +x /usr/local/bin/kubectl
# /root 는 compose 가 홈 볼륨으로 덮는다 — CLI 는 /usr/local 에 전역 설치한다.
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force
RUN printf 'export PS1="\[\e[32m\]lab\[\e[0m\]:\w\$ "\nalias k=kubectl\n' > /etc/profile.d/lab.sh
COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH=/root/.local/bin:/opt/java/openjdk/bin:$PATH
# 터미널은 로그인 셸(bash -l)이라 alpine 의 /etc/profile 이 PATH 를 다시 쓴다 — 거기서도 java 가 보이게.
RUN printf 'export JAVA_HOME=/opt/java/openjdk\nexport PATH="/root/.local/bin:$JAVA_HOME/bin:$PATH"\n' > /etc/profile.d/java.sh
# alpine 의 python 은 pip 전역 설치를 막는다(PEP 668) — 컨테이너가 곧 격리 환경이다.
ENV PIP_BREAK_SYSTEM_PACKAGES=1
# pip 설치는 홈(/root/.local, 홈 볼륨)으로 — 컨테이너를 다시 만들어도 남고 pytest·uvicorn 이 PATH 에 있다.
ENV PIP_USER=1
# 빌드 검증 — 하나라도 실행되지 않으면 빌드가 깨진다. java 는 25 여야 한다.
RUN node --version && python3 --version && pip --version && claude --version && codex --version \
 && java -version 2>&1 | head -1 && java -version 2>&1 | grep -q '"25'
WORKDIR /work
CMD ["sleep", "infinity"]
