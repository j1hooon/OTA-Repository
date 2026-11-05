output "s3_bucket_name" {
  value = aws_s3_bucket.firmware.id
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.firmware_cdn.domain_name
}

output "jenkins_iam_access_key_id" {
  value = aws_iam_access_key.jenkins_uploader.id
}

output "jenkins_iam_secret_access_key" {
  value     = aws_iam_access_key.jenkins_uploader.secret
  sensitive = true
}
