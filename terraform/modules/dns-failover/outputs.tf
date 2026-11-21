output "name_servers" {
  value = aws_route53_zone.main.name_servers
}

output "zone_id" {
  value = aws_route53_zone.main.zone_id
}

output "heartbeat_access_key_id" {
  value = aws_iam_access_key.heartbeat_sender.id
}

output "heartbeat_secret_access_key" {
  value     = aws_iam_access_key.heartbeat_sender.secret
  sensitive = true
}
