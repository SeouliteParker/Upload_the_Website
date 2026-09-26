#!/usr/bin/env bash
# EC2 인스턴스 내부에서 실행하는 요구사항 점검 스크립트.
#   ssh -i ~/.ssh/upload-the-website-key.pem ubuntu@<퍼블릭IP> 'bash -s' < infra/verify-on-instance.sh
set -uo pipefail

pass=0; fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "[PASS] $name"; pass=$((pass+1)); else echo "[FAIL] $name"; fail=$((fail+1)); fi
}
http_code() { curl -s -o /dev/null -m 5 -w '%{http_code}' "$1"; }

echo "== 인스턴스 정보 =="
TOKEN=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
for p in instance-id instance-type placement/availability-zone local-ipv4 public-ipv4; do
  printf '%-28s %s\n' "$p" "$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$p")"
done
echo

echo "== 요구사항 점검 =="
check "아웃바운드 인터넷: https://example.com → 200" [ "$(http_code https://example.com)" = "200" ]
if command -v docker >/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q .; then
  check "Docker 컨테이너 Up" bash -c "docker ps --filter name=hello-cloud --format '{{.Status}}' | grep -q '^Up'"
  docker ps
else
  check "Nginx 서비스 active" systemctl is-active --quiet nginx
fi
check "curl http://localhost → 200" [ "$(http_code http://localhost)" = "200" ]
check "curl http://localhost/health → 200 OK" [ "$(curl -s -m 5 http://localhost/health)" = "OK" ]
check "80 포트 LISTEN" bash -c "ss -ltn | grep -q ':80 '"

echo
echo "결과: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
