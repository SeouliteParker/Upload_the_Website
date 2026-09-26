#!/bin/bash
# EC2 최초 부팅 시 1회 실행 (Ubuntu 24.04 LTS). 로그: /var/log/cloud-init-output.log
# 아래 base64 자리표시자(__*_B64__)는 provision.sh 가 app/ 파일 내용으로 치환한다.
set -euxo pipefail

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx curl

mkdir -p /usr/share/nginx/html
echo '__INDEX_HTML_B64__' | base64 -d > /usr/share/nginx/html/index.html
echo '__NGINX_CONF_B64__' | base64 -d > /etc/nginx/sites-available/default

nginx -t
systemctl enable --now nginx
systemctl reload nginx

# 배포 직후 자체 점검 결과를 cloud-init 로그에 남긴다.
curl -s -o /dev/null -w 'localhost / -> %{http_code}\n' http://localhost/
curl -s -w ' (localhost /health -> %{http_code})\n' http://localhost/health
