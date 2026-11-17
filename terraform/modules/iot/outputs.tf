output "iot_endpoint" {
  description = "AWS IoT Core Data-ATS Endpoint"
  value       = data.aws_iot_endpoint.data_ats.endpoint_address
}

output "iot_thing_name" {
  value = aws_iot_thing.esp32_fleet.name
}

output "fastapi_iot_access_key_id" {
  value = aws_iam_access_key.ota_api_publisher.id
}

output "fastapi_iot_secret_access_key" {
  value     = aws_iam_access_key.ota_api_publisher.secret
  sensitive = true
}

output "device_certificate_pem" {
  sensitive   = true
  description = "ESP32 디바이스 X.509 인증서(PEM)"
  value       = aws_iot_certificate.esp32_fleet.certificate_pem
}

output "device_private_key" {
  description = "ESP32 디바이스 개인키(PEM). state 에 평문 저장되므로 취급 주의"
  value       = aws_iot_certificate.esp32_fleet.private_key
  sensitive   = true
}
