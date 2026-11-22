# Terraform state 보호용 부트스트랩 (S3 + KMS + 잠금)
#
# 이 설정은 state 버킷을 "만드는" 설정이라 자기 state 는 로컬에 둔다(비밀 없음: 버킷/키 ARN 만 포함).
# 메인 설정(terraform/)이 이 버킷을 백엔드로 쓴다. 사용법은 README 참고.
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-northeast-1"
}

variable "use_dynamodb_lock" {
  description = "Terraform < 1.10 이면 true (DynamoDB 잠금). 1.10 이상이면 false 로 두고 S3 자체 잠금(use_lockfile)을 쓴다."
  type        = bool
  default     = false
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "HA-OTA-Platform", ManagedBy = "Terraform", Purpose = "tfstate" }
  }
}

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "ota-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  lock_line   = var.use_dynamodb_lock ? "dynamodb_table = \"ota-tfstate-lock\"" : "use_lockfile = true"
}

# --- KMS 고객 관리 키 -------------------------------------------------------
resource "aws_kms_key" "tfstate" {
  description             = "Encrypts Terraform state (OTA platform)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  lifecycle { prevent_destroy = true }
}

resource "aws_kms_alias" "tfstate" {
  name          = "alias/ota-tfstate"
  target_key_id = aws_kms_key.tfstate.key_id
}

# --- State 버킷 ------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.bucket_name
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.tfstate.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

# 오래된 버전은 90일 뒤 정리(롤백 가능 기간), 미완료 업로드 정리
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  depends_on = [aws_s3_bucket_versioning.tfstate]
  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# TLS 가 아닌 접근은 모두 거부
data "aws_iam_policy_document" "tfstate" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.tfstate.arn, "${aws_s3_bucket.tfstate.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  policy     = data.aws_iam_policy_document.tfstate.json
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# --- (선택) DynamoDB 잠금: Terraform < 1.10 -------------------------------
resource "aws_dynamodb_table" "lock" {
  count        = var.use_dynamodb_lock ? 1 : 0
  name         = "ota-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"
  attribute {
    name = "LockID"
    type = "S"
  }
  server_side_encryption { enabled = true }
}

output "backend_hcl" {
  description = "terraform/backend.hcl 에 그대로 저장 (git 에 올리지 말 것: 계정 ID 포함)"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.tfstate.id}"
    key          = "ota-platform/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    kms_key_id   = "${aws_kms_key.tfstate.arn}"
    ${local.lock_line}
  EOT
}
