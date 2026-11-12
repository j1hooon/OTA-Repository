FROM jenkins/jenkins:lts-jdk21

USER root

# Jenkinsfile이 사용하는 도구: gcc(빌드 벤치마크), bc(시간 계산), psql, redis-cli, curl, unzip
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential bc curl unzip ca-certificates postgresql-client redis-tools \
    && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 (펌웨어를 S3에 업로드)
RUN ARCH="$(uname -m)" \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# kubectl (K3s 클러스터 상태 검증)
RUN ARCH="$(dpkg --print-architecture)" \
    && KVER="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
    && curl -fsSL "https://dl.k8s.io/release/${KVER}/bin/linux/${ARCH}/kubectl" -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# docker-compose에서 user: root로 실행하므로 USER는 root 유지
