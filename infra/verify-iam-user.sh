#!/usr/bin/env bash
# 실습에 실제로 사용한 IAM 사용자(기본: cloud-mission-user)에
# infra/iam-policy.json(UploadTheWebsiteLeastPrivilege) 단 하나만 연결되어 있고,
# 인라인 정책이나 그룹을 통한 추가 권한이 없는지 확인한다.
#   ./infra/verify-iam-user.sh [사용자명]
#
# 관리자 권한(iam:List*, iam:Get*)이 있는 별도 자격 증명으로 실행한다.
# cloud-mission-user 자신은 iam:List*/iam:Get* 권한이 없어 이 스크립트를 실행할 수
# 없는데, 그 자체가 최소권한이 실제로 적용되어 있다는 근거이기도 하다.
set -uo pipefail

USER_NAME="${1:-cloud-mission-user}"
EXPECTED_POLICY="${EXPECTED_POLICY_NAME:-UploadTheWebsiteLeastPrivilege}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

pass=0; fail=0
check() {
  local name="$1"; shift
  if "$@"; then echo "[PASS] $name"; pass=$((pass+1)); else echo "[FAIL] $name"; fail=$((fail+1)); fi
}

echo "== 대상 IAM 사용자: $USER_NAME =="

ATTACHED="$(aws iam list-attached-user-policies --user-name "$USER_NAME" \
  --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null)"
echo "연결된 관리형 정책: ${ATTACHED:-(조회 실패 또는 없음)}"
check "관리형 정책이 '$EXPECTED_POLICY' 단 하나만 연결됨" \
  [ "$ATTACHED" = "$EXPECTED_POLICY" ]

INLINE="$(aws iam list-user-policies --user-name "$USER_NAME" \
  --query 'PolicyNames' --output text 2>/dev/null)"
echo "인라인 정책: ${INLINE:-(없음)}"
check "인라인 정책 없음" bash -c "[ -z '$INLINE' ] || [ '$INLINE' = 'None' ]"

GROUPS="$(aws iam list-groups-for-user --user-name "$USER_NAME" \
  --query 'Groups[].GroupName' --output text 2>/dev/null)"
echo "소속 그룹: ${GROUPS:-(없음)}"
check "소속 그룹 없음(그룹을 통한 추가 권한 없음)" bash -c "[ -z '$GROUPS' ] || [ '$GROUPS' = 'None' ]"

POLICY_ARN="$(aws iam list-policies --scope Local \
  --query "Policies[?PolicyName=='$EXPECTED_POLICY'].Arn | [0]" --output text 2>/dev/null)"
if [[ -n "$POLICY_ARN" && "$POLICY_ARN" != "None" ]]; then
  VERSION_ID="$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)"
  aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$VERSION_ID" \
    --query 'PolicyVersion.Document' --output json > /tmp/attached-iam-policy.json 2>/dev/null
  check "연결된 정책 문서가 infra/iam-policy.json과 일치함" bash -c \
    "diff -q <(python3 -m json.tool '$ROOT_DIR/infra/iam-policy.json') <(python3 -m json.tool /tmp/attached-iam-policy.json) >/dev/null"
else
  check "계정에서 '$EXPECTED_POLICY' 관리형 정책을 찾음" false
fi

echo
echo "결과: PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
