# 보너스 2: Nginx 컨테이너로 웹 서비스 배포
# 빌드 컨텍스트는 저장소 루트:  docker build -f docker/Dockerfile -t hello-cloud:1.0 .
FROM nginx:1.27-alpine

COPY app/nginx.conf /etc/nginx/conf.d/default.conf
COPY app/index.html /usr/share/nginx/html/index.html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://127.0.0.1/health || exit 1
