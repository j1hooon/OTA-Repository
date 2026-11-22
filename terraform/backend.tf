# 원격 state (S3 + KMS). 값은 backend.hcl 로 주입한다:  terraform init -backend-config=backend.hcl
# (bucket 이름에 계정 ID 가 들어가므로 backend.hcl 은 커밋하지 않는다. backend.hcl.example 참고)
terraform {
  backend "s3" {}
}
