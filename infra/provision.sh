#!/usr/bin/env bash
# VPC → Public Subnet → IGW → Route Table → Security Group → Key Pair → EC2 를
# 서울 리전(ap-northeast-2)에 순서대로 생성한다.
#
# 사용법 (루트 계정이 아닌, infra/iam-policy.json 이 연결된 IAM 사용자 자격 증명으로 실행):
#   ./infra/provision.sh                 # 호스트에 Nginx 직접 설치
#   MODE=docker ./infra/provision.sh     # 보너스 2: Docker 컨테이너로 Nginx 실행
#
# 생성된 리소스 ID는 infra/.state.env 에 기록되고 cleanup.sh 가 이를 사용한다.
set -euo pipefail

export AWS_REGION="${AWS_REGION:-ap-northeast-2}"
export AWS_DEFAULT_REGION="$AWS_REGION"
PROJECT="${PROJECT:-upload-the-website}"
MODE="${MODE:-nginx}"                         # nginx | docker
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"    # t2.micro | t3.micro (IAM 정책이 그 외 타입을 거부)
AZ="${AZ:-${AWS_REGION}a}"
VPC_CIDR="10.0.0.0/16"
SUBNET_CIDR="10.0.1.0/24"
KEY_NAME="${KEY_NAME:-${PROJECT}-key}"
KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
AMI_PARAM="/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_FILE="$ROOT_DIR/infra/.state.env"

if [[ "$AWS_REGION" != "ap-northeast-2" ]]; then
  echo "모든 리소스는 서울 리전(ap-northeast-2)에 생성해야 합니다." >&2; exit 1
fi
if [[ -f "$STATE_FILE" ]]; then
  echo "$STATE_FILE 이 이미 존재합니다. 먼저 ./infra/cleanup.sh 로 정리하세요." >&2; exit 1
fi

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
save() { echo "$1=$2" >> "$STATE_FILE"; }
tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=${PROJECT}-$2},{Key=Project,Value=${PROJECT}}]"; }

log "호출자 확인 (루트 계정 사용 금지)"
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "$CALLER_ARN"
if [[ "$CALLER_ARN" == *":root" ]]; then
  echo "루트 계정으로는 실행하지 않습니다. IAM 사용자 자격 증명을 사용하세요." >&2; exit 1
fi

MY_IP="${MY_IP:-$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')}"
echo "SSH 허용 IP: ${MY_IP}/32"
: > "$STATE_FILE"
save AWS_REGION "$AWS_REGION"
save KEY_NAME "$KEY_NAME"

log "1. VPC ($VPC_CIDR)"
VPC_ID=$(aws ec2 create-vpc --cidr-block "$VPC_CIDR" \
  --tag-specifications "$(tags vpc vpc)" --query Vpc.VpcId --output text)
save VPC_ID "$VPC_ID"
aws ec2 wait vpc-available --vpc-ids "$VPC_ID"
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'
echo "$VPC_ID"

log "2. Public Subnet ($SUBNET_CIDR, $AZ)"
SUBNET_ID=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block "$SUBNET_CIDR" \
  --availability-zone "$AZ" --tag-specifications "$(tags subnet public-subnet)" \
  --query Subnet.SubnetId --output text)
save SUBNET_ID "$SUBNET_ID"
# 이 서브넷에 뜨는 인스턴스에 퍼블릭 IPv4 자동 할당
aws ec2 modify-subnet-attribute --subnet-id "$SUBNET_ID" --map-public-ip-on-launch
echo "$SUBNET_ID"

log "3. Internet Gateway 생성 및 VPC 연결"
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "$(tags internet-gateway igw)" \
  --query InternetGateway.InternetGatewayId --output text)
save IGW_ID "$IGW_ID"
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"
echo "$IGW_ID → $VPC_ID"

log "4. Public Route Table (0.0.0.0/0 → IGW) 및 서브넷 연결"
RTB_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags route-table public-rt)" \
  --query RouteTable.RouteTableId --output text)
save RTB_ID "$RTB_ID"
aws ec2 create-route --route-table-id "$RTB_ID" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" >/dev/null
RTB_ASSOC_ID=$(aws ec2 associate-route-table --route-table-id "$RTB_ID" \
  --subnet-id "$SUBNET_ID" --query AssociationId --output text)
save RTB_ASSOC_ID "$RTB_ASSOC_ID"
aws ec2 describe-route-tables --route-table-ids "$RTB_ID" \
  --query 'RouteTables[0].Routes[].[DestinationCidrBlock,GatewayId,State]' --output table

log "5. Security Group (80: 0.0.0.0/0, 22: ${MY_IP}/32)"
SG_ID=$(aws ec2 create-security-group --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-web-sg" --description "HTTP from anywhere, SSH from my IP only" \
  --tag-specifications "$(tags security-group web-sg)" --query GroupId --output text)
save SG_ID "$SG_ID"
aws ec2 authorize-security-group-ingress --group-id "$SG_ID" --ip-permissions \
  "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description=HTTP-public}]" \
  "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description=SSH-my-ip}]" >/dev/null
aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$SG_ID" \
  --query 'SecurityGroupRules[].[IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4]' --output table

log "6. Key Pair ($KEY_NAME)"
if [[ -f "$KEY_FILE" ]]; then
  echo "기존 키 파일 $KEY_FILE 이 있어 재사용합니다 (AWS 측 키 페어 이름도 동일해야 함)."
else
  mkdir -p "$(dirname "$KEY_FILE")"
  aws ec2 create-key-pair --key-name "$KEY_NAME" --key-type ed25519 \
    --tag-specifications "$(tags key-pair key)" \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "개인 키 저장: $KEY_FILE (재발급 불가 — 안전하게 보관)"
fi

log "7. User Data 생성 (MODE=$MODE)"
# 임시 파일 + file:// 대신 내용을 변수로 직접 만든다. Windows Git Bash(MSYS)가
# /tmp 경로를 aws.exe(네이티브 윈도우 바이너리)에 잘못 변환해 "No such file or
# directory" 오류가 나는 문제를 피하기 위함 (docs/troubleshooting.md 참고).
b64() { base64 < "$1" | tr -d '\n'; }
USER_DATA="$(sed -e "s|__INDEX_HTML_B64__|$(b64 "$ROOT_DIR/app/index.html")|" \
    -e "s|__NGINX_CONF_B64__|$(b64 "$ROOT_DIR/app/nginx.conf")|" \
    -e "s|__DOCKERFILE_B64__|$(b64 "$ROOT_DIR/docker/Dockerfile")|" \
    "$ROOT_DIR/infra/user-data-${MODE}.sh")"

log "8. EC2 인스턴스 ($INSTANCE_TYPE, Ubuntu 24.04 LTS, gp3 8GiB)"
INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "resolve:ssm:${AMI_PARAM}" \
  --instance-type "$INSTANCE_TYPE" \
  --key-name "$KEY_NAME" \
  --subnet-id "$SUBNET_ID" \
  --security-group-ids "$SG_ID" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":8,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data "$USER_DATA" \
  --tag-specifications "$(tags instance web)" "$(tags volume root)" \
  --query 'Instances[0].InstanceId' --output text)
save INSTANCE_ID "$INSTANCE_ID"
echo "$INSTANCE_ID — running 상태 대기 중..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
save PUBLIC_IP "$PUBLIC_IP"

cat <<MSG

======================================================================
 배포 요청 완료. user-data(패키지 설치)가 끝나기까지 1~3분 걸립니다.

 퍼블릭 IP : $PUBLIC_IP
 (A) 브라우저 : http://$PUBLIC_IP
 (B) 헬스체크 : curl -i http://$PUBLIC_IP/health
 SSH         : ssh -i $KEY_FILE ubuntu@$PUBLIC_IP
 인스턴스 점검: ssh ... 'bash -s' < infra/verify-on-instance.sh

 실습이 끝나면 반드시: ./infra/cleanup.sh
======================================================================
MSG
