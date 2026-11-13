data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# 1. AWS IoT Core Data-ATS 엔드포인트 조회
data "aws_iot_endpoint" "data_ats" {
  endpoint_type = "iot:Data-ATS"
}

# 2. 대표 ESP32 디바이스(Thing) 등록
resource "aws_iot_thing" "esp32_fleet" {
  name = "${var.environment}-esp32-device-01"
  attributes = {
    model = "ESP32-WROOM-32"
    role  = "ota-client"
  }
}

# 3. 디바이스용 IoT Policy (MQTT Connect, Subscribe ota/notify/*, Publish ota/status/* 허용)
data "aws_iam_policy_document" "device_iot_policy" {
  statement {
    sid       = "AllowMQTTConnect"
    effect    = "Allow"
    actions   = ["iot:Connect"]
    resources = ["arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:client/*"]
  }

  statement {
    sid       = "AllowOTANotifySubscribe"
    effect    = "Allow"
    actions   = ["iot:Subscribe"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topicfilter/ota/notify/*"
    ]
  }

  statement {
    sid       = "AllowOTANotifyReceive"
    effect    = "Allow"
    actions   = ["iot:Receive"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/ota/notify/*"
    ]
  }

  statement {
    sid       = "AllowOTAStatusPublish"
    effect    = "Allow"
    actions   = ["iot:Publish"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/ota/status/*"
    ]
  }
}

resource "aws_iot_policy" "device_policy" {
  name   = "${var.environment}-device-mqtt-policy"
  policy = data.aws_iam_policy_document.device_iot_policy.json
}

# 4. FastAPI 서버(ota_api) 전용 IAM User & Key (ota/notify/* 토픽 Publish 최소 권한)
resource "aws_iam_user" "ota_api_publisher" {
  name = "${var.environment}-fastapi-iot-publisher"
}

resource "aws_iam_access_key" "ota_api_publisher" {
  user = aws_iam_user.ota_api_publisher.name
}

data "aws_iam_policy_document" "ota_api_iot_publish" {
  statement {
    sid     = "AllowFastAPIIoTPublish"
    effect  = "Allow"
    actions = ["iot:Publish", "iot:DescribeEndpoint"]
    resources = [
      "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:topic/ota/notify/*"
    ]
  }
}

resource "aws_iam_user_policy" "ota_api_publisher" {
  name   = "${var.environment}-fastapi-iot-publish-policy"
  user   = aws_iam_user.ota_api_publisher.name
  policy = data.aws_iam_policy_document.ota_api_iot_publish.json
}
