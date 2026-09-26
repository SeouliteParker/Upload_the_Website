#!/bin/bash
# 보너스 2: Docker 컨테이너로 Nginx 웹 서비스 실행 (Ubuntu 24.04 LTS).
# 로그: /var/log/cloud-init-output.log
set -euxo pipefail

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io curl
systemctl enable --now docker
usermod -aG docker ubuntu

# 저장소의 docker/Dockerfile 과 동일한 빌드 컨텍스트를 재구성한다.
mkdir -p /opt/hello-cloud/app /opt/hello-cloud/docker
echo '__INDEX_HTML_B64__' | base64 -d > /opt/hello-cloud/app/index.html
echo '__NGINX_CONF_B64__' | base64 -d > /opt/hello-cloud/app/nginx.conf
echo '__DOCKERFILE_B64__' | base64 -d > /opt/hello-cloud/docker/Dockerfile

docker build -f /opt/hello-cloud/docker/Dockerfile -t hello-cloud:1.0 /opt/hello-cloud
docker rm -f hello-cloud 2>/dev/null || true
docker run -d --name hello-cloud --restart unless-stopped -p 80:80 hello-cloud:1.0

sleep 3
docker ps --filter name=hello-cloud
curl -s -o /dev/null -w 'localhost / -> %{http_code}\n' http://localhost/
curl -s -w ' (localhost /health -> %{http_code})\n' http://localhost/health
