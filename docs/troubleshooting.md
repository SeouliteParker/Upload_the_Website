# 트러블슈팅 보고서

모든 건은 **증상 → 가설 → 검증 → 조치 → 결과 → 재발 방지** 순서로 기록한다.

| # | 구분 | 한 줄 요약 | 상태 |
|---|------|-----------|------|
| 1 | 애플리케이션 | 컨테이너 기동 직후 Nginx 종료: `socket() [::]:80 failed (97)` | 해결. 실제 로그 기반 |
| 2 | 네트워크(라우팅) | EC2는 running인데 외부에서 `http://<퍼블릭IP>` 타임아웃 | 재현 절차와 판별법 정리. 배포 시 결과 기입 |
| 3 | 보안 그룹 | 어제 되던 SSH가 오늘 `Operation timed out` | 재현 절차와 판별법 정리. 배포 시 결과 기입 |
| 4 | IAM | `RunInstances` 호출 시 `UnauthorizedOperation` | 재현 절차와 판별법 정리. 배포 시 결과 기입 |

> 1번은 배포 전에 로컬에서 Docker 이미지를 검증하다 **실제로 발생한** 오류이고, 아래 로그를 그대로 옮겼다.
> 2~4번은 이 구성에서 가장 흔히 겪는 통신/권한 오류다. 원인을 일부러 만들어 재현하는 절차와 로그로 판별하는 방법을 적어 두었다.
> 실제 AWS에서 재현했을 때 나온 출력과 스크린샷은 각 건의 `결과` 칸에 붙인다.

---

## 1. Nginx 컨테이너가 뜨자마자 종료됨 (IPv6 listen 실패)

| 항목 | 내용 |
|------|------|
| **증상** | `docker run -d -p 8080:80 hello-cloud:1.0` 직후 `curl localhost:8080/health`가 `000`(연결 실패)을 반환했다. `docker ps -a` 상태는 `Exited (1)`이었다. |
| **원인 가설** | ① 포트 매핑 오류 ② 설정 파일 문법 오류 ③ 설정은 맞지만 실행 환경이 지원하지 않는 지시어가 있음 |
| **검증 방법** | `docker logs hello-cloud`로 종료 직전 로그를 확인했다(아래). `nginx -t` 문법 검사를 통과했으므로 ②는 기각했다. 프로세스가 아예 뜨지 않았으니 ①도 기각했다. 로그의 `errno 97 (Address family not supported)`는 해당 네트워크 네임스페이스에서 **IPv6 소켓을 만들 수 없다**는 뜻이므로 ③이 맞다. |
| **조치 내용** | `app/nginx.conf`에서 `listen [::]:80 default_server;`를 삭제했다. 이번 VPC는 IPv6 CIDR이 없는 **IPv4 전용**이라 IPv6 listen이 필요하지 않다. |
| **결과** | 재빌드 후 `docker ps`에 `Up (healthy)`로 표시되고 `GET /health`는 `200 OK`, 본문 `OK`를 반환했다. `/`는 200, 없는 경로는 404로 정상이다. |
| **재발 방지** | ① 배포 전에 로컬에서 `docker build && docker run && curl /health` 스모크 테스트를 한다. ② Dockerfile `HEALTHCHECK`가 `/health`를 주기적으로 호출하게 해서 비정상 상태를 `docker ps`에서 바로 보이게 했다. ③ 설정 파일에는 실제 네트워크 구성(IPv4 전용)에 맞는 지시어만 둔다. |

실제 로그:

```text
$ docker ps -a
CONTAINER ID   IMAGE             STATUS                     NAMES
5e55c34ec1cc   hello-cloud:1.0   Exited (1) 5 seconds ago   hello-cloud

$ docker logs hello-cloud
10-listen-on-ipv6-by-default.sh: info: ipv6 not available
/docker-entrypoint.sh: Configuration complete; ready for start up
nginx: [emerg] socket() [::]:80 failed (97: Address family not supported by protocol)
```

조치 후:

```text
$ docker ps
CONTAINER ID   IMAGE             STATUS                            PORTS                  NAMES
fba27e8986c5   hello-cloud:1.0   Up 3 seconds (health: starting)   0.0.0.0:8080->80/tcp   hello-cloud

$ curl -i localhost:8080/health
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/plain
Content-Length: 3

OK
```

---

## 2. 인스턴스는 running인데 외부에서 웹 접속이 타임아웃됨 (라우팅 누락)

| 항목 | 내용 |
|------|------|
| **증상** | 브라우저와 `curl -m 5 http://<퍼블릭IP>` 모두 `Connection timed out`. 인스턴스 상태는 running, 상태 검사 2/2 통과. |
| **원인 가설** | ① SG 인바운드 80이 없음 ② Nginx가 떠 있지 않음 ③ 서브넷의 라우트 테이블에 `0.0.0.0/0 → IGW`가 없음(서브넷이 **기본(main) RT**에 연결됨) ④ 인스턴스에 퍼블릭 IP가 없음 |
| **검증 방법** | 안쪽에서 바깥쪽 순서로 좁힌다.<br>② `aws ec2 get-console-output --instance-id <id> --latest`로 cloud-init 로그에 `localhost / -> 200`이 있는지 본다(SSH가 안 될 때도 확인할 수 있다).<br>① `aws ec2 describe-security-group-rules --filters Name=group-id,Values=<sg>`<br>④ `aws ec2 describe-instances --query 'Reservations[].Instances[].PublicIpAddress'`<br>③ `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<subnet>`. 결과가 비어 있으면 서브넷이 main RT를 쓰고 있다는 뜻이다. main RT에는 `local` 경로만 있다.<br>보조: `curl https://example.com`을 인스턴스 안에서 실행했을 때 아웃바운드도 실패하면 ③일 가능성이 높다(응답 패킷이 돌아올 경로가 없다). |
| **조치 내용** | 퍼블릭 RT에 `create-route --destination-cidr-block 0.0.0.0/0 --gateway-id <igw>`를 추가하고 `associate-route-table --subnet-id <subnet>`으로 서브넷에 명시적으로 연결한다. |
| **결과** | _(배포 시 기입: 조치 전 `describe-route-tables` 출력, 조치 후 `curl -i http://<IP>/health` 200 스크린샷)_ |
| **재발 방지** | `provision.sh` 4단계에서 경로 생성과 서브넷 연결을 한 번에 하고, 생성 직후 라우트 테이블을 표로 출력해 `0.0.0.0/0 → igw-… active`를 눈으로 확인한다. 배포 체크리스트에 "퍼블릭 서브넷 = IGW 경로가 있는 RT에 연결된 서브넷"을 추가한다. |

재현 방법: 아래 명령으로 서브넷 연결을 끊어 main RT로 되돌리면 같은 증상이 나타난다. 확인한 뒤 다시 연결한다.

```bash
aws ec2 disassociate-route-table --association-id "$RTB_ASSOC_ID"
curl -m 5 -i http://$PUBLIC_IP/health     # → timeout
aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID"
```

---

## 3. 어제 되던 SSH가 오늘 타임아웃됨 (SG 소스 IP 불일치)

| 항목 | 내용 |
|------|------|
| **증상** | `ssh -i key.pem ubuntu@<IP>` → `connect to host <IP> port 22: Operation timed out`. 같은 시각 `http://<IP>/health`는 200. |
| **원인 가설** | ① 인스턴스 장애 ② 키 파일 문제 ③ 내 공인 IP가 바뀌어서(다른 Wi-Fi, 통신사 재할당) SG 22번 규칙의 `/32` 소스와 맞지 않음 |
| **검증 방법** | HTTP가 200이므로 ①(인스턴스와 네트워크 경로)은 기각한다. 키 문제면 `Permission denied (publickey)`가 **즉시** 돌아와야 한다. **타임아웃**은 패킷이 필터에서 버려졌다는 신호이므로 ②도 기각한다. `curl https://checkip.amazonaws.com`으로 현재 IP를 SG 규칙의 CIDR과 비교해 불일치를 확인한다. 증거가 더 필요하면 VPC Flow Logs에서 `dstport=22 action=REJECT` 레코드를 찾는다. |
| **조치 내용** | 기존 22번 규칙을 `revoke`한 뒤 새 IP로 `authorize-security-group-ingress --protocol tcp --port 22 --cidr <새IP>/32`를 실행한다. **0.0.0.0/0으로 여는 것은 금지.** |
| **결과** | _(배포 시 기입: 규칙 변경 전후 SG 화면, SSH 접속 성공 화면)_ |
| **재발 방지** | 증상의 종류로 원인 계층을 먼저 가른다. 타임아웃이면 네트워크/필터, 즉시 거부면 인증/서비스다. `provision.sh`는 실행할 때마다 현재 IP를 자동으로 조회한다. 작업이 끝나면 22번 규칙을 삭제하는 것도 방법이다. |

---

## 4. `RunInstances` 호출 시 `UnauthorizedOperation` (IAM 최소권한)

| 항목 | 내용 |
|------|------|
| **증상** | `An error occurred (UnauthorizedOperation) when calling the RunInstances operation: You are not authorized to perform this operation. Encoded authorization failure message: …` |
| **원인 가설** | ① 리전이 서울이 아님(`aws:RequestedRegion` 조건 불일치) ② 인스턴스 타입이 t2/t3.micro가 아님(명시적 Deny) ③ 루트 볼륨이 10GiB를 넘음(명시적 Deny) ④ AMI 조회용 `ssm:GetParameters` 권한 없음 |
| **검증 방법** | 인코딩된 메시지를 디코딩한다(정책에 `sts:DecodeAuthorizationMessage`를 허용해 둔 이유).<br>`aws sts decode-authorization-message --encoded-message <msg> --query DecodedMessage --output text \| python3 -m json.tool`<br>출력의 `matchedStatements`에 `DenyNonFreeTierInstanceTypes`처럼 **어느 Statement가 거부했는지**와 `context.action`, `resource`가 나온다. |
| **조치 내용** | 요청을 정책에 맞춘다(예: `INSTANCE_TYPE=t3.micro`, 볼륨 8GiB, `AWS_REGION=ap-northeast-2`). **권한을 넓히는 것은 마지막 수단**이고, 그때도 필요한 Action 하나만 추가한다. |
| **결과** | _(배포 시 기입: 디코딩된 메시지 일부와 재실행 성공 출력)_ |
| **재발 방지** | 정책의 Deny 조건을 README에 명시한다. 스크립트 기본값을 정책과 일치시켜 두었다(t3.micro, 8GiB, ap-northeast-2). |

재현 방법:

```bash
INSTANCE_TYPE=t3.small ./infra/provision.sh   # → UnauthorizedOperation (DenyNonFreeTierInstanceTypes)
./infra/cleanup.sh                            # 도중에 만들어진 VPC 등 정리
```

---

## 부록: 계층별 점검 순서 (바깥 → 안)

1. **DNS/IP**: 접속하려는 IP가 현재 인스턴스의 퍼블릭 IP인가? (중지 후 시작하면 바뀐다. EIP를 쓰지 않았을 때)
2. **라우팅**: 서브넷 RT에 `0.0.0.0/0 → igw`가 있는가? IGW가 VPC에 attach되어 있는가?
3. **보안 그룹**: 해당 포트와 소스 CIDR이 허용되어 있는가? (SG는 stateful이라 응답 규칙은 필요 없다)
4. **NACL**: 기본 NACL(전체 허용)을 바꾸지 않았는가? (NACL은 stateless라 에페메랄 포트 1024-65535 아웃바운드도 필요하다)
5. **OS/서비스**: `systemctl status nginx`, `ss -ltn | grep :80`, `curl localhost`
6. **애플리케이션 로그**: `/var/log/nginx/error.log`, `/var/log/cloud-init-output.log`, `docker logs`
