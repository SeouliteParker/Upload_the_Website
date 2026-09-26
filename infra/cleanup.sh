#!/usr/bin/env bash
# provision.sh 로 만든 리소스를 "의존성 역순"으로 삭제한다.
#   EC2 종료(→ 루트 EBS 자동 삭제) → EIP 해제 → SG → RT → IGW 분리/삭제 → Subnet → VPC → Key Pair
# 이후 Project 태그 기준으로 남은 과금 리소스가 없는지 재확인한다.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$ROOT_DIR/infra/.state.env"
PROJECT="${PROJECT:-upload-the-website}"
export AWS_REGION="${AWS_REGION:-ap-northeast-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"

log() { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
run() { echo "+ $*"; "$@" || echo "  (실패 또는 이미 삭제됨 — 계속 진행)"; }

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
else
  echo "$STATE_FILE 이 없어 Project=$PROJECT 태그로 리소스를 찾습니다."
  q() { aws ec2 "$@" --filters "Name=tag:Project,Values=$PROJECT" --output text; }
  VPC_ID=$(q describe-vpcs --query 'Vpcs[0].VpcId')
  INSTANCE_ID=$(q describe-instances --query 'Reservations[].Instances[?State.Name!=`terminated`].InstanceId | [0]')
  SUBNET_ID=$(q describe-subnets --query 'Subnets[0].SubnetId')
  IGW_ID=$(q describe-internet-gateways --query 'InternetGateways[0].InternetGatewayId')
  RTB_ID=$(q describe-route-tables --query 'RouteTables[0].RouteTableId')
  SG_ID=$(q describe-security-groups --query 'SecurityGroups[0].GroupId')
  KEY_NAME="${PROJECT}-key"
fi
isset() { [[ -n "${1:-}" && "$1" != "None" ]]; }

log "1. EC2 종료 (루트 EBS는 DeleteOnTermination=true 로 함께 삭제)"
if isset "${INSTANCE_ID:-}"; then
  run aws ec2 terminate-instances --instance-ids "$INSTANCE_ID" --query 'TerminatingInstances[].CurrentState.Name' --output text
  echo "terminated 대기 중..."
  run aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"
fi

log "2. Elastic IP 해제 (할당했다면)"
for alloc in $(aws ec2 describe-addresses --filters "Name=tag:Project,Values=$PROJECT" \
                --query 'Addresses[].AllocationId' --output text); do
  run aws ec2 release-address --allocation-id "$alloc"
done

log "3. Security Group 삭제"
isset "${SG_ID:-}" && run aws ec2 delete-security-group --group-id "$SG_ID"

log "4. Route Table 연결 해제 및 삭제"
if isset "${RTB_ID:-}"; then
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
                  --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text 2>/dev/null); do
    run aws ec2 disassociate-route-table --association-id "$assoc"
  done
  run aws ec2 delete-route-table --route-table-id "$RTB_ID"
fi

log "5. Internet Gateway 분리(Detach) 후 삭제"
if isset "${IGW_ID:-}"; then
  isset "${VPC_ID:-}" && run aws ec2 detach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
  run aws ec2 delete-internet-gateway --internet-gateway-id "$IGW_ID"
fi

log "6. Subnet 삭제"
isset "${SUBNET_ID:-}" && run aws ec2 delete-subnet --subnet-id "$SUBNET_ID"

log "7. VPC 삭제 (기본 RT/NACL/SG 는 VPC 와 함께 삭제됨)"
isset "${VPC_ID:-}" && run aws ec2 delete-vpc --vpc-id "$VPC_ID"

log "8. Key Pair 삭제"
isset "${KEY_NAME:-}" && run aws ec2 delete-key-pair --key-name "$KEY_NAME"
LOCAL_KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME:-upload-the-website-key}.pem}"
if [[ -f "$LOCAL_KEY_FILE" ]]; then
  echo "AWS 키 페어는 삭제됐지만 로컬 개인 키가 남아 있습니다: $LOCAL_KEY_FILE"
  echo "다음에 provision.sh 를 다시 실행할 때 자동으로 새 키로 교체되지만,"
  echo "직접 지우려면: rm -f \"$LOCAL_KEY_FILE\""
fi

log "9. 잔여 리소스 확인 (모두 비어 있어야 정리 완료)"
F="Name=tag:Project,Values=$PROJECT"
echo "- EC2 (terminated 제외):";   aws ec2 describe-instances --filters "$F" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --query 'Reservations[].Instances[].InstanceId' --output text
echo "- EBS 볼륨 (프로젝트 태그):"; aws ec2 describe-volumes --filters "$F" --query 'Volumes[].[VolumeId,State]' --output text
echo "- EBS 미사용(available) 볼륨 전체:"; aws ec2 describe-volumes --filters Name=status,Values=available --query 'Volumes[].[VolumeId,Size]' --output text
echo "- Elastic IP 전체:";          aws ec2 describe-addresses --query 'Addresses[].[PublicIp,AllocationId]' --output text
echo "- NAT Gateway (삭제 안 된 것):"; aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available --query 'NatGateways[].NatGatewayId' --output text
echo "- Internet Gateway:";         aws ec2 describe-internet-gateways --filters "$F" --query 'InternetGateways[].InternetGatewayId' --output text
echo "- VPC:";                      aws ec2 describe-vpcs --filters "$F" --query 'Vpcs[].VpcId' --output text

rm -f "$STATE_FILE"
echo
echo "정리 완료. docs/cleanup-checklist.md 에 결과를 기록하고 Billing 대시보드를 확인하세요."
