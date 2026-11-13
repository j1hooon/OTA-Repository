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
