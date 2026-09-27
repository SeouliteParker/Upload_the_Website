# 스크린샷

메인 [`README.md`의 "스크린샷" 섹션](../../README.md#스크린샷)에 미리보기와 함께 정리되어 있다. 이 폴더에는 원본 파일만 둔다.

| 파일 | 내용 | 상태 |
|------|------|------|
| `browser.png` | 브라우저로 `http://<IP>` 접속, "Hello Cloud" 페이지 정상 표시 (외부 접속 검증 A) | ✅ |
| `health-200.png` | `curl -i http://<IP>/health` → `200 OK` / `OK` (외부 접속 검증 B, 선택 방식) | ✅ |
| `verify-on-instance.png` | `infra/verify-on-instance.sh` 실행 결과, PASS=5 FAIL=0 | ✅ |
| `security-group.png` | Security Group 인바운드 규칙(80: 0.0.0.0/0, 22: 내 IP/32) | ✅ |
| `route-table.png` | Route Table 경로(`0.0.0.0/0 → igw`, `10.0.0.0/16 → local`) | ✅ |
| `cleanup-terminal.png` | `infra/cleanup.sh` 최종 실행 로그, 잔여 리소스 확인 결과 전부 비어 있음 | ✅ |
| `iam-permissions.png` | IAM → 사용자 `cloud-mission-user` → 권한 탭, `UploadTheWebsiteLeastPrivilege` 정책 하나만 연결됨(그룹/인라인 정책 없음). `infra/verify-iam-user.sh` 실행 결과로도 교차 확인 | 선택, 미실시 |
| `docker-ps.png` | (보너스 2) `docker ps`에서 컨테이너 `Up` 상태 | 선택, 미실시 |
| `docker-external.png` | (보너스 2) 외부에서 `/health` 호출 결과 | 선택, 미실시 |
| `billing.png` | (선택) Billing 대시보드에서 과금 항목 없음 확인 | 선택, 미실시 |
