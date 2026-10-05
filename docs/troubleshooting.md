# 트러블슈팅 보고서

모든 건은 **증상 → 가설 → 검증 → 조치 → 결과 → 재발 방지** 순서로 기록한다.

| # | 구분 | 한 줄 요약 | 상태 |
|---|------|-----------|------|
| 1 | 애플리케이션 | 컨테이너 기동 직후 Nginx 종료: `socket() [::]:80 failed (97)` | 해결. 실제 로그 기반 |
| 2 | 네트워크(라우팅) | EC2는 running인데 외부에서 `http://<퍼블릭IP>` 타임아웃 | 재현·판별 가이드 (미실행) |
| 3 | 보안 그룹 | 어제 되던 SSH가 오늘 `Operation timed out` | 재현·판별 가이드 (미실행) |
| 4 | IAM | `RunInstances` 호출 시 `UnauthorizedOperation` | 재현·판별 가이드 (미실행) |
| 5 | 배포 스크립트(Windows) | `RunInstances` 호출 시 `Unable to load paramfile file:///tmp/...: No such file or directory` | 해결. 실제 로그 기반 |
| 6 | 배포 스크립트(키 페어) | 재배포 시 `InvalidKeyPair.NotFound` | 해결. 실제 로그 기반 |
| 7 | SSH(Windows) | `Load key "...pem": invalid format` → `Permission denied (publickey)` | 해결. 실제 로그 기반 |
| 8 | 배포 스크립트(Windows, Git 설정) | 원격 점검 스크립트가 `$'\r': command not found` / `syntax error` | 해결. 실제 로그 기반 |

> 1, 5, 6, 7, 8번은 이 저장소를 실제로 배포하면서 **실제로 발생한** 오류이고, 로그와 조치를 그대로 옮겼다.
> 2~4번은 **실제로 발생하지 않은** 예상 오류다. 이 구성에서 가장 흔히 겪는 통신/권한 오류를 골라, 원인을 일부러 만들어 재현하는 절차와 로그로 판별하는 방법을 정리한 **가이드**다.
> 실습 중 재현하지 않았으므로 `결과` 칸에는 "기대 결과"만 적었다. 실제 출력으로 오해하지 않도록 구분해 둔다.

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

## 2. [가이드] 인스턴스는 running인데 외부에서 웹 접속이 타임아웃됨 (라우팅 누락)

| 항목 | 내용 |
|------|------|
| **증상** | 브라우저와 `curl -m 5 http://<퍼블릭IP>` 모두 `Connection timed out`. 인스턴스 상태는 running, 상태 검사 2/2 통과. |
| **원인 가설** | ① SG 인바운드 80이 없음 ② Nginx가 떠 있지 않음 ③ 서브넷의 라우트 테이블에 `0.0.0.0/0 → IGW`가 없음(서브넷이 **기본(main) RT**에 연결됨) ④ 인스턴스에 퍼블릭 IP가 없음 |
| **검증 방법** | 안쪽에서 바깥쪽 순서로 좁힌다.<br>② `aws ec2 get-console-output --instance-id <id> --latest`로 cloud-init 로그에 `localhost / -> 200`이 있는지 본다(SSH가 안 될 때도 확인할 수 있다).<br>① `aws ec2 describe-security-group-rules --filters Name=group-id,Values=<sg>`<br>④ `aws ec2 describe-instances --query 'Reservations[].Instances[].PublicIpAddress'`<br>③ `aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=<subnet>`. 결과가 비어 있으면 서브넷이 main RT를 쓰고 있다는 뜻이다. main RT에는 `local` 경로만 있다.<br>보조: `curl https://example.com`을 인스턴스 안에서 실행했을 때 아웃바운드도 실패하면 ③일 가능성이 높다(응답 패킷이 돌아올 경로가 없다). |
| **조치 내용** | 퍼블릭 RT에 `create-route --destination-cidr-block 0.0.0.0/0 --gateway-id <igw>`를 추가하고 `associate-route-table --subnet-id <subnet>`으로 서브넷에 명시적으로 연결한다. |
| **결과(기대)** | _미실행._ 조치 후 `curl -i http://<IP>/health`가 `200 OK` / `OK`를 반환해야 한다. |
| **재발 방지** | `provision.sh` 4단계에서 경로 생성과 서브넷 연결을 한 번에 하고, 생성 직후 라우트 테이블을 표로 출력해 `0.0.0.0/0 → igw-… active`를 눈으로 확인한다. 배포 체크리스트에 "퍼블릭 서브넷 = IGW 경로가 있는 RT에 연결된 서브넷"을 추가한다. |

재현 방법: 아래 명령으로 서브넷 연결을 끊어 main RT로 되돌리면 같은 증상이 나타난다. 확인한 뒤 다시 연결한다.

```bash
aws ec2 disassociate-route-table --association-id "$RTB_ASSOC_ID"
curl -m 5 -i http://$PUBLIC_IP/health     # → timeout
aws ec2 associate-route-table --route-table-id "$RTB_ID" --subnet-id "$SUBNET_ID"
```

---

## 3. [가이드] 어제 되던 SSH가 오늘 타임아웃됨 (SG 소스 IP 불일치)

| 항목 | 내용 |
|------|------|
| **증상** | `ssh -i key.pem ubuntu@<IP>` → `connect to host <IP> port 22: Operation timed out`. 같은 시각 `http://<IP>/health`는 200. |
| **원인 가설** | ① 인스턴스 장애 ② 키 파일 문제 ③ 내 공인 IP가 바뀌어서(다른 Wi-Fi, 통신사 재할당) SG 22번 규칙의 `/32` 소스와 맞지 않음 |
| **검증 방법** | HTTP가 200이므로 ①(인스턴스와 네트워크 경로)은 기각한다. 키 문제면 `Permission denied (publickey)`가 **즉시** 돌아와야 한다. **타임아웃**은 패킷이 필터에서 버려졌다는 신호이므로 ②도 기각한다. `curl https://checkip.amazonaws.com`으로 현재 IP를 SG 규칙의 CIDR과 비교해 불일치를 확인한다. 증거가 더 필요하면 VPC Flow Logs에서 `dstport=22 action=REJECT` 레코드를 찾는다. |
| **조치 내용** | 기존 22번 규칙을 `revoke`한 뒤 새 IP로 `authorize-security-group-ingress --protocol tcp --port 22 --cidr <새IP>/32`를 실행한다. **0.0.0.0/0으로 여는 것은 금지.** |
| **결과(기대)** | _미실행._ 새 IP로 규칙을 바꾸면 SSH가 즉시 접속되고, HTTP 80은 영향 없이 계속 200이어야 한다. |
| **재발 방지** | 증상의 종류로 원인 계층을 먼저 가른다. 타임아웃이면 네트워크/필터, 즉시 거부면 인증/서비스다. `provision.sh`는 실행할 때마다 현재 IP를 자동으로 조회한다. 작업이 끝나면 22번 규칙을 삭제하는 것도 방법이다. |

---

## 4. [가이드] `RunInstances` 호출 시 `UnauthorizedOperation` (IAM 최소권한)

| 항목 | 내용 |
|------|------|
| **증상** | `An error occurred (UnauthorizedOperation) when calling the RunInstances operation: You are not authorized to perform this operation. Encoded authorization failure message: …` |
| **원인 가설** | ① 리전이 서울이 아님(`aws:RequestedRegion` 조건 불일치) ② 인스턴스 타입이 t2/t3.micro가 아님(명시적 Deny) ③ 루트 볼륨이 10GiB를 넘음(명시적 Deny) ④ AMI 조회용 `ssm:GetParameters` 권한 없음 |
| **검증 방법** | 인코딩된 메시지를 디코딩한다(정책에 `sts:DecodeAuthorizationMessage`를 허용해 둔 이유).<br>`aws sts decode-authorization-message --encoded-message <msg> --query DecodedMessage --output text \| python3 -m json.tool`<br>출력의 `matchedStatements`에 `DenyNonFreeTierInstanceTypes`처럼 **어느 Statement가 거부했는지**와 `context.action`, `resource`가 나온다. |
| **조치 내용** | 요청을 정책에 맞춘다(예: `INSTANCE_TYPE=t3.micro`, 볼륨 8GiB, `AWS_REGION=ap-northeast-2`). **권한을 넓히는 것은 마지막 수단**이고, 그때도 필요한 Action 하나만 추가한다. |
| **결과(기대)** | _미실행._ 디코딩 결과에 거부한 Statement(예: `DenyNonFreeTierInstanceTypes`)가 나오고, 정책 범위로 요청을 고치면 `RunInstances`가 성공해야 한다. |
| **재발 방지** | 정책의 Deny 조건을 README에 명시한다. 스크립트 기본값을 정책과 일치시켜 두었다(t3.micro, 8GiB, ap-northeast-2). |

재현 방법:

```bash
INSTANCE_TYPE=t3.small ./infra/provision.sh   # → UnauthorizedOperation (DenyNonFreeTierInstanceTypes)
./infra/cleanup.sh                            # 도중에 만들어진 VPC 등 정리
```

---

## 5. Windows에서 `RunInstances` 호출 시 `Unable to load paramfile ... No such file or directory`

| 항목 | 내용 |
|------|------|
| **증상** | Windows의 Git Bash(VS Code 통합 터미널)에서 `./infra/provision.sh` 실행 시 8단계(EC2 생성)에서 실패.<br>`aws: [ERROR]: An error occurred (ParamValidation): Error parsing parameter '--user-data': Unable to load paramfile file:///tmp/tmp.p4y6SbT4fz: [Errno 2] No such file or directory` |
| **원인 가설** | ① user-data 스크립트 자체를 못 만듦(사전 sed/base64 실패) ② `mktemp`이 만든 임시 파일을 스크립트가 조기에 지움 ③ Git Bash(MSYS)가 `file:///tmp/...` 안의 유닉스 경로를 **aws.exe(네이티브 Windows 바이너리)에 넘길 때 잘못 변환**해서, CLI가 실제 파일 위치와 다른 경로를 찾음 |
| **검증 방법** | macOS/Linux(같은 스크립트, 같은 AWS 계정)에서는 동일 단계가 성공했으므로 스크립트 로직(①)은 기각했다. 에러 메시지의 파일 경로가 `mktemp`가 실제로 만든 경로와 달랐다(Git Bash에서 `mktemp` 결과를 직접 `ls`로 대조). Windows에서만, 그것도 `file://` 경로를 쓰는 지점에서만 재현되므로 ③으로 좁혔다. 이는 Git Bash의 "자동 경로 변환(automatic path conversion)"이 MSYS와 링크되지 않은 외부 프로그램에 인자를 넘길 때 유닉스 스타일 경로(`/tmp/...`)를 잘못 다루는, 잘 알려진 동작이다. |
| **조치 내용** | `infra/provision.sh`에서 `--user-data file://$TMPFILE` 대신, 렌더링한 user-data 내용을 **셸 변수에 직접 담아 값으로 전달**하도록 바꿨다(`--user-data "$USER_DATA"`). 파일 경로를 아예 거치지 않으므로 OS별 경로 변환 문제와 무관해진다. |
| **결과** | 수정 후 같은 Windows(Git Bash) 환경에서 8단계를 통과해 `InstanceId`를 정상 반환했다(다음 건인 #6과 이어짐). |
| **재발 방지** | 로컬에서 (fake credentials로) `aws ec2 run-instances --user-data "$UD" --dry-run`을 실행해, 파라미터 파싱을 통과하고 인증 단계에서 실패하는지로 문법 오류를 사전에 구분하는 습관을 들인다. macOS/Linux에서만 검증하고 배포 스크립트를 완료 처리하지 않는다 — 이 미션 참여자 다수가 Windows를 쓰므로 Windows 실행 경로도 실제로 검증한다. |

---

## 6. 재배포 시 `InvalidKeyPair.NotFound`

| 항목 | 내용 |
|------|------|
| **증상** | `./infra/cleanup.sh`로 한 번 정리한 뒤 `./infra/provision.sh`를 다시 실행하면 8단계에서<br>`An error occurred (InvalidKeyPair.NotFound) when calling the RunInstances operation: The key pair 'upload-the-website-key' does not exist` |
| **원인 가설** | `provision.sh` 6단계는 로컬에 `~/.ssh/upload-the-website-key.pem` 파일이 **있기만 하면** AWS 쪽에도 같은 이름의 키 페어가 있다고 가정하고 새로 만들지 않는다. 그런데 `cleanup.sh`는 AWS 쪽 키 페어만 삭제하고 로컬 `.pem` 파일은 남겨 두므로, 정리 후 재배포하면 "로컬 파일은 있는데 AWS 키는 없는" 상태가 된다. |
| **검증 방법** | `aws ec2 describe-key-pairs --key-names upload-the-website-key` 실행 → `InvalidKeyPair.NotFound` 확인(로컬 `.pem`은 여전히 존재). 스크립트의 재사용 조건이 로컬 파일 존재만 검사하고 AWS 쪽 존재는 검사하지 않았음을 코드로 확인. |
| **조치 내용** | `provision.sh` 6단계를 "로컬 `.pem` 존재 **그리고** `aws ec2 describe-key-pairs`로 AWS 쪽 존재 확인"을 모두 만족할 때만 재사용하도록 바꿨다. 둘 중 하나라도 어긋나면 기존 `.pem`을 `.bak`으로 옮기고 새 키 페어를 발급한다. `cleanup.sh`도 AWS 키 삭제 후 로컬 `.pem`이 남아 있으면 안내 메시지를 출력하도록 했다. |
| **결과** | 수정 후 정리→재배포를 반복해도 매번 유효한 키 페어로 EC2가 정상 생성됐다. |
| **재발 방지** | "로컬 파일이 있다 = AWS에도 있다"처럼 **로컬 상태로 원격 상태를 추정하지 않는다.** 재사용 전에 항상 원격에서 한 번 확인한다. `cleanup.sh`가 지운 리소스와 짝을 이루는 로컬 산출물(`.pem`, `infra/.state.env`)도 함께 안내한다. |

---

## 7. Windows에서 발급받은 `.pem`으로 SSH 접속 시 `invalid format`

| 항목 | 내용 |
|------|------|
| **증상** | 배포는 성공하고 `curl http://<IP>/health`도 200이 나오는데, SSH만 실패.<br>`Load key "/c/Users/.../upload-the-website-key.pem": invalid format`<br>`ubuntu@<IP>: Permission denied (publickey).` |
| **원인 가설** | ① 키 페어 자체가 인스턴스와 안 맞음(다른 키로 발급) ② PEM 파일 권한 문제 ③ Windows에서 `aws ec2 create-key-pair ... --output text > file`로 저장하는 과정에서 **줄바꿈이 CRLF(`\r\n`)로 저장**되어 OpenSSH의 PEM 파서가 형식을 인식하지 못함 |
| **검증 방법** | HTTP는 정상이므로 EC2/네트워크(①과 무관한 계층)는 문제가 없다. SSH 클라이언트가 아예 "not a permission denied by server"가 아니라 "invalid format"이라며 **키를 읽는 단계에서** 실패했으므로 서버 인증 이전, 로컬 키 파일 문제로 좁혔다. `cat -A ~/.ssh/upload-the-website-key.pem \| head -1`로 줄 끝에 `^M`(캐리지 리턴)이 보이면 ③ 확정. (Windows에서 CLI가 표준출력을 텍스트 모드로 다룰 때 흔히 생긴다.) |
| **조치 내용** | 즉시 조치: `tr -d '\r' < key.pem > key.pem.fixed && mv key.pem.fixed key.pem && chmod 400 key.pem`으로 CRLF를 제거.<br>근본 조치: `infra/provision.sh`의 키 저장 파이프라인에 `\| tr -d '\r'`을 추가해, 어느 OS에서 실행하든 항상 LF만 남긴 PEM 파일을 쓰도록 고쳤다. |
| **결과** | 수정 후 같은 Windows(Git Bash) 환경에서 `ssh -i key.pem ubuntu@<IP>`가 정상 접속되고, `infra/verify-on-instance.sh` 점검도 통과했다. |
| **재발 방지** | Windows에서 텍스트로 저장되는 민감한 바이너리성 산출물(PEM, 인증서 등)은 저장 직후 줄바꿈 형식을 검사하거나 강제로 LF로 통일한다. macOS/Linux에서만 되는지 확인하고 끝내지 않고, Windows 경로도 실제로 SSH까지 접속해본다. |

---

## 8. Windows에서 `verify-on-instance.sh`를 SSH로 실행하면 `$'\r': command not found`

| 항목 | 내용 |
|------|------|
| **증상** | SSH 접속 자체는 성공(#7 해결 후)했는데, `ssh ... 'bash -s' < infra/verify-on-instance.sh` 실행 시 원격(Ubuntu)에서<br>`: invalid option name`, `bash: line 5: $'\r': command not found`, `` bash: line 7: syntax error near unexpected token `$'{\r'' `` |
| **원인 가설** | ① 스크립트 문법 오류(저장소의 스크립트 자체가 깨짐) ② `ssh`가 stdin을 잘못 전달 ③ **Windows의 Git이 저장소를 체크아웃할 때 `core.autocrlf` 설정으로 `.sh` 파일 줄바꿈을 CRLF로 바꿔서**, 로컬(Git Bash)에서는 문제없이 보여도 리눅스 bash가 CRLF를 명령어 일부로 오해함 |
| **검증 방법** | 같은 저장소를 macOS/Linux에서 clone 했을 때는 이 오류가 없었으므로 ①은 기각. `cat -A infra/verify-on-instance.sh \| head -3`으로 각 줄 끝에 `^M$`이 보이면 ③ 확정(정상이면 `$`만 있어야 함). `git config core.autocrlf` 값이 Windows 기본인 `true`였다. |
| **조치 내용** | 즉시 조치(로컬 파일만 교정): `sed -i 's/\r$//' infra/verify-on-instance.sh` 후 재실행.<br>근본 조치: 저장소 루트에 `.gitattributes`를 추가해 `*.sh`, `*.conf` 등 텍스트 파일을 `eol=lf`로 강제했다. 이러면 OS의 `core.autocrlf` 설정과 무관하게 체크아웃 시 항상 LF로 받는다. 이미 CRLF로 받아둔 기존 클론은 `git add --renormalize . && git commit`으로 한 번 정규화해야 한다. |
| **결과** | `.gitattributes` 적용 후 새로 clone(또는 `git add --renormalize .`)하면 Windows에서도 `verify-on-instance.sh`가 원격에서 정상 실행되어 모든 항목이 `[PASS]`로 나왔다. |
| **재발 방지** | 여러 OS에서 실행되는(특히 "이 기기에서 만들어 다른 기기/원격으로 보내는") 텍스트 파일은 저장소 차원에서 `.gitattributes`로 줄바꿈을 고정한다. 로컬 git 설정(`core.autocrlf`)에 결과가 좌우되게 두지 않는다. |

---

## 부록: 계층별 점검 순서 (바깥 → 안)

1. **DNS/IP**: 접속하려는 IP가 현재 인스턴스의 퍼블릭 IP인가? (중지 후 시작하면 바뀐다. EIP를 쓰지 않았을 때)
2. **라우팅**: 서브넷 RT에 `0.0.0.0/0 → igw`가 있는가? IGW가 VPC에 attach되어 있는가?
3. **보안 그룹**: 해당 포트와 소스 CIDR이 허용되어 있는가? (SG는 stateful이라 응답 규칙은 필요 없다)
4. **NACL**: 기본 NACL(전체 허용)을 바꾸지 않았는가? (NACL은 stateless라 에페메랄 포트 1024-65535 아웃바운드도 필요하다)
5. **OS/서비스**: `systemctl status nginx`, `ss -ltn | grep :80`, `curl localhost`
6. **애플리케이션 로그**: `/var/log/nginx/error.log`, `/var/log/cloud-init-output.log`, `docker logs`
