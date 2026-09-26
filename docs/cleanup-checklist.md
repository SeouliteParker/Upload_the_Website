# 리소스 정리 체크리스트

실습 리소스는 **생성할 때부터 `Project=upload-the-website` 태그로 추적**한다. 정리는 **의존성 역순**으로 한다.
자동 정리는 `./infra/cleanup.sh`로 하고, 아래 표의 "확인 명령"으로 하나씩 검증한 뒤 결과를 기입한다.

- 정리 일시: `YYYY-MM-DD HH:MM (KST)`
- 리전: `ap-northeast-2`
- 작업자(IAM 사용자): `cloud-mission-user`

## 왜 이 순서인가

```
EC2 종료 ─▶ (루트 EBS 자동 삭제) ─▶ EIP 해제 ─▶ SG 삭제 ─▶ RT 연결해제/삭제
        ─▶ IGW Detach ─▶ IGW 삭제 ─▶ Subnet 삭제 ─▶ VPC 삭제 ─▶ Key Pair 삭제
```

- 인스턴스의 ENI가 SG와 Subnet을 참조하고 있다. **EC2가 terminated가 되기 전에는** SG와 Subnet이 `DependencyViolation`으로 지워지지 않는다.
- IGW가 VPC에 attach된 상태에서는 IGW도 VPC도 삭제할 수 없다. **Detach가 먼저**다.
- EIP는 인스턴스에서 떼어진 뒤에도 **계속 과금된다**. 인스턴스를 종료해도 자동으로 해제되지 않는다.
- EBS는 `DeleteOnTermination=false`이거나 별도로 만든 볼륨이면 **남아서 과금된다**. `available` 상태 볼륨을 반드시 확인한다.

## 필수 정리 항목

| # | 리소스 | 완료 기준 | 확인 명령 | 결과 |
|---|--------|-----------|-----------|------|
| 1 | EC2 인스턴스 | 상태 `terminated` | `aws ec2 describe-instances --filters Name=tag:Project,Values=upload-the-website --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table` | ☐ |
| 2 | EBS 볼륨(미사용 포함) | 프로젝트 볼륨 0개, `available` 볼륨 0개 | `aws ec2 describe-volumes --query 'Volumes[].[VolumeId,State,Size]' --output table` | ☐ |
| 3 | Elastic IP | 할당된 주소 0개(할당했다면 Release 완료) | `aws ec2 describe-addresses --output table` | ☐ |
| 4 | Security Group | `upload-the-website-web-sg` 없음 | `aws ec2 describe-security-groups --filters Name=tag:Project,Values=upload-the-website` | ☐ |
| 5 | Route Table | 퍼블릭 RT 없음 | `aws ec2 describe-route-tables --filters Name=tag:Project,Values=upload-the-website` | ☐ |
| 6 | Internet Gateway | Detach 후 삭제되어 조회 결과 없음 | `aws ec2 describe-internet-gateways --filters Name=tag:Project,Values=upload-the-website` | ☐ |
| 7 | Subnet | 조회 결과 없음 | `aws ec2 describe-subnets --filters Name=tag:Project,Values=upload-the-website` | ☐ |
| 8 | VPC | 조회 결과 없음 | `aws ec2 describe-vpcs --filters Name=tag:Project,Values=upload-the-website` | ☐ |
| 9 | Key Pair | AWS 측 키 삭제, 로컬 `.pem` 파기 | `aws ec2 describe-key-pairs --key-names upload-the-website-key` → NotFound | ☐ |

## 해당 시 정리 항목 (이번 구성에서는 만들지 않음)

| 리소스 | 완료 기준 | 확인 명령 | 결과 |
|--------|-----------|-----------|------|
| NAT Gateway | `deleted` (IAM 정책에서 생성 자체를 Deny) | `aws ec2 describe-nat-gateways --filter Name=state,Values=pending,available` | ☐ 해당 없음 |
| ELB/ALB | 없음 | 콘솔 EC2 → 로드 밸런서 | ☐ 해당 없음 |
| RDS | 없음 | 콘솔 RDS → 데이터베이스(IAM 권한 없음) | ☐ 해당 없음 |
| EBS 스냅샷/AMI | 직접 만든 것 없음 | `aws ec2 describe-snapshots --owner-ids self` | ☐ |

## 과금 관점 메모

| 과금 요인 | 이번 구성에서의 주의점 |
|-----------|------------------------|
| EC2 실행 시간 | t3.micro, 프리 티어 한도 내. **stopped여도 EBS는 과금**되므로 끝나면 terminate한다. |
| EBS 용량 | gp3 8GiB 1개. 종료 시 자동 삭제(`DeleteOnTermination=true`)되도록 설정했다. |
| 퍼블릭 IPv4 주소 | 2024-02부터 모든 퍼블릭 IPv4가 시간당 과금 대상이다(프리 티어로 750시간/월 상쇄). 사용하지 않는 EIP도 과금된다. |
| 데이터 전송 | 인터넷 방향 아웃바운드는 월 100GB까지 무료다. 실습 수준에서는 무시할 만하다. |
| NAT Gateway | 시간당 + GB당 과금으로 프리 티어가 없다. 그래서 정책으로 생성을 막았다. |

## 최종 확인

- [ ] `./infra/cleanup.sh` 마지막 "잔여 리소스 확인" 출력이 모두 비어 있다.
- [ ] 콘솔 **EC2 대시보드**(서울 리전)에서 인스턴스, 볼륨, 탄력적 IP, 보안 그룹(default 제외) 수가 0이다.
- [ ] 콘솔 **VPC 대시보드**에서 기본 VPC 외에 남은 VPC가 없다.
- [ ] (권장) **Billing and Cost Management → 청구서/Free Tier** 화면에서 예상 과금이 없다.
      (IAM 사용자로 보려면 관리자가 IAM 사용자의 결제 정보 접근을 활성화하고 `billing:View*` 읽기 권한을 따로 부여해야 한다.)
- [ ] 증빙 스크린샷: `docs/screenshots/cleanup-ec2.png`, `docs/screenshots/cleanup-vpc.png`, (선택) `docs/screenshots/billing.png`
