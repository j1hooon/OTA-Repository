output "vpc_id" {
  value = module.vpc.vpc_id
}

output "public_subnet_id" {
  value = module.vpc.public_subnet_id
}

output "k3s_security_group_id" {
  value = module.vpc.k3s_security_group_id
}

output "db_security_group_id" {
  value = module.vpc.db_security_group_id
}

output "s3_bucket_name" {
  value = module.s3_cloudfront.s3_bucket_name
}

output "cloudfront_domain_name" {
  value = module.s3_cloudfront.cloudfront_domain_name
}

output "jenkins_iam_access_key_id" {
  value = module.s3_cloudfront.jenkins_iam_access_key_id
}

output "jenkins_iam_secret_access_key" {
  value     = module.s3_cloudfront.jenkins_iam_secret_access_key
  sensitive = true
}
