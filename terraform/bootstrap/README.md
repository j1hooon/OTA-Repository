# Terraform state 부트스트랩 (S3 + KMS + 잠금)

state 에는 IoT 디바이스 개인키, IAM 액세스 키 비밀값, Tailscale 키(user_data)가 평문으로 들어 있다.
로컬 파일 대신 암호화된 원격 백엔드로 옮겨 보호하고 이력(버전)과 잠금을 얻는다.

| 보호 | 구현 |
|---|---|
| 저장 시 암호화 | S3 SSE-KMS, 고객 관리 키(자동 회전), bucket key |
| 전송 암호화 | 버킷 정책으로 TLS 아닌 접근 거부 |
| 공개 차단 | public access block 4종 + BucketOwnerEnforced |
| 실수 복구 | 버전닝(오래된 버전 90일 보관) |
| 동시 실행 방지 | S3 `use_lockfile`(Terraform >= 1.10) 또는 DynamoDB |
| 삭제 방지 | 버킷/KMS 키 `prevent_destroy` |

한계: 암호화는 "저장 매체 유출"을 막을 뿐, AWS 권한이 있는 사람이 state 를 읽는 것은 막지 못한다.
(state 를 읽을 수 있는 IAM 주체를 최소화하는 것이 다음 단계)

## 절차 (mgmt 의 저장소 루트)
1. `terraform version` 이 1.10 미만이면 2단계에서 `-var use_dynamodb_lock=true` 를 붙인다.
2. `cd terraform/bootstrap && terraform init && terraform apply`
3. `terraform output -raw backend_hcl > ../backend.hcl`   (git 에 올리지 않는다)
4. 저장소 루트에서 `./apply.sh --enable-backend` (backend.tf 활성화)
5. `cd terraform && terraform init -migrate-state -backend-config=backend.hcl`  -> `yes`
