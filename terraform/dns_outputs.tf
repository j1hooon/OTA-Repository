# 모듈 outputs 는 모듈 안에서 정의하고, 루트에서 다시 내보낸다.
output "route53_name_servers" {
  description = "가비아에 등록할 Route 53 네임서버 4개"
  value       = module.dns_failover.name_servers
}

output "heartbeat_iam_access_key_id" {
  value = module.dns_failover.heartbeat_access_key_id
}

output "heartbeat_iam_secret_access_key" {
  value     = module.dns_failover.heartbeat_secret_access_key
  sensitive = true
}
