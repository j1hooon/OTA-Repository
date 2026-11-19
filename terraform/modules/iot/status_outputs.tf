output "device_status_queue_url" {
  description = "기기 상태 수집 SQS 큐 URL (Ansible Vault 의 device_status_queue_url 로 사용)"
  value       = aws_sqs_queue.device_status.url
}

output "device_status_dlq_url" {
  value = aws_sqs_queue.device_status_dlq.url
}
