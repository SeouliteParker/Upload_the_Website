# 스크린샷

배포 후 아래 파일명으로 캡처해 이 폴더에 넣는다. (퍼블릭 IP 외 계정 ID나 액세스 키가 보이지 않게 가린다.)

| 파일 | 내용 | 필수 |
|------|------|------|
| `health-200.png` | 외부 PC에서 실행한 `curl -i http://<IP>/health` → 200 OK | ✅ |
| `browser.png` | 브라우저로 `http://<IP>` 접속한 화면 | |
| `verify-on-instance.png` | `infra/verify-on-instance.sh` 결과 (PASS) | |
| `security-group.png` | SG 인바운드 규칙 | |
| `route-table.png` | RT 경로와 서브넷 연결 | |
| `docker-ps.png` | (보너스 2) `docker ps`에서 컨테이너 Up | 보너스 ✅ |
| `docker-external.png` | (보너스 2) 외부에서 `/health` 호출 결과 | 보너스 ✅ |
| `cleanup-ec2.png` / `cleanup-vpc.png` | 정리 후 리소스 목록 | |
| `billing.png` | (선택) Billing 대시보드 | |
