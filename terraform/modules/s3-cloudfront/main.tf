# 고유한 S3 버킷 이름을 위해 현재 AWS Account ID 조회
data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.environment}-firmware-${data.aws_caller_identity.current.account_id}"
}

# 1. Private S3 Bucket (펌웨어 바이너리 저장소)
resource "aws_s3_bucket" "firmware" {
  bucket        = local.bucket_name
  force_destroy = true # 실습 환경 정리(destroy) 시 내부에 파일이 있어도 삭제 가능하도록 설정

  tags = {
    Name = local.bucket_name
  }
}

# 2. S3 퍼블릭 액세스 전면 차단 (Block All Public Access)
resource "aws_s3_bucket_public_access_block" "firmware" {
  bucket = aws_s3_bucket.firmware.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 3. CloudFront Origin Access Control (OAC) 생성
resource "aws_cloudfront_origin_access_control" "firmware_oac" {
  name                              = "${var.environment}-s3-oac"
  description                       = "OAC for private ESP32 firmware S3 bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 4. CloudFront Distribution (글로벌 CDN)
resource "aws_cloudfront_distribution" "firmware_cdn" {
  enabled             = true
  is_ipv6_enabled     = false
  comment             = "OTA Firmware Binary CDN (${var.environment})"
  price_class         = "PriceClass_200" # 한국, 일본(도쿄), 아시아 및 북미/유럽 포함 (비용 최적화)

  origin {
    domain_name              = aws_s3_bucket.firmware.bucket_regional_domain_name
    origin_id                = "S3-${aws_s3_bucket.firmware.id}"
    origin_access_control_id = aws_cloudfront_origin_access_control.firmware_oac.id
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "S3-${aws_s3_bucket.firmware.id}"
    viewer_protocol_policy = "allow-all" # ESP32 HTTP/HTTPS 모두 호환
    compress               = false       # .bin 바이너리 파일이므로 압축 불필요

    # AWS Managed CachingOptimized 정책 ID (바이너리 캐싱 극대화)
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "${var.environment}-cdn"
  }
}

# 5. S3 Bucket Policy: 오직 위 CloudFront 배포(OAC)에서의 읽기만 허용
data "aws_iam_policy_document" "s3_cloudfront_oac" {
  statement {
    sid       = "AllowCloudFrontServicePrincipalReadOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.firmware.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.firmware_cdn.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "firmware" {
  bucket = aws_s3_bucket.firmware.id
  policy = data.aws_iam_policy_document.s3_cloudfront_oac.json
}

# 6. Jenkins CI/CD 전용 최소 권한 IAM User (S3 업로드 전용)
resource "aws_iam_user" "jenkins_uploader" {
  name = "${var.environment}-jenkins-s3-uploader"
}

resource "aws_iam_access_key" "jenkins_uploader" {
  user = aws_iam_user.jenkins_uploader.name
}

data "aws_iam_policy_document" "jenkins_s3_upload" {
  statement {
    sid       = "AllowFirmwareUploadOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.firmware.arn,
      "${aws_s3_bucket.firmware.arn}/*"
    ]
  }
}

resource "aws_iam_user_policy" "jenkins_uploader" {
  name   = "${var.environment}-jenkins-s3-policy"
  user   = aws_iam_user.jenkins_uploader.name
  policy = data.aws_iam_policy_document.jenkins_s3_upload.json
}
