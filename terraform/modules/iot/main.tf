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

# 3. 디바이스용 IoT Policy (기기별 스코핑)
#    - IoT policy variable(&{iot:Connection.Thing.ThingName}) 사용: 인증서가 붙은 Thing 이름과
#      MQTT Client ID 가 같을 때만 연결되고, 자기 이름의 토픽만 구독/발행할 수 있다.
#    - 전체 브로드캐스트 토픽은 ota/notify/all, 개별 지시는 ota/notify/<ThingName>.
#    (aws_iam_policy_document 에서 "&{" 는 "${" 로 변환된다)
locals {
  iot_arn_prefix = "arn:aws:iot:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}"
}

data "aws_iam_policy_document" "device_iot_policy" {
  statement {
    sid       = "AllowMQTTConnectAsOwnThing"
    effect    = "Allow"
    actions   = ["iot:Connect"]
    resources = ["${local.iot_arn_prefix}:client/&{iot:Connection.Thing.ThingName}"]
  }

  statement {
    sid     = "AllowOTANotifySubscribe"
    effect  = "Allow"
    actions = ["iot:Subscribe"]
    resources = [
      "${local.iot_arn_prefix}:topicfilter/ota/notify/all",
      "${local.iot_arn_prefix}:topicfilter/ota/notify/&{iot:Connection.Thing.ThingName}",
    ]
  }

  statement {
    sid     = "AllowOTANotifyReceive"
    effect  = "Allow"
    actions = ["iot:Receive"]
    resources = [
      "${local.iot_arn_prefix}:topic/ota/notify/all",
      "${local.iot_arn_prefix}:topic/ota/notify/&{iot:Connection.Thing.ThingName}",
    ]
  }

  statement {
    sid       = "AllowOTAStatusPublishOwnTopic"
    effect    = "Allow"
    actions   = ["iot:Publish"]
    resources = ["${local.iot_arn_prefix}:topic/ota/status/&{iot:Connection.Thing.ThingName}"]
  }
}

resource "aws_iot_policy" "device_policy" {
  name   = "${var.environment}-device-mqtt-policy"
  policy = data.aws_iam_policy_document.device_iot_policy.json
}

# 3-1. 디바이스 X.509 인증서 발급 및 Policy / Thing 연결
#      주의: private_key 는 Terraform state 에 평문으로 저장된다 -> state 는 절대 커밋하지 말 것(.gitignore 처리됨).
#      실제 양산 기기는 기기 내부에서 CSR 을 생성(aws_iot_certificate 의 csr 인자)해 키가 밖으로 나오지 않게 한다.
resource "aws_iot_certificate" "esp32_fleet" {
  active = true
}

resource "aws_iot_policy_attachment" "esp32_fleet" {
  policy = aws_iot_policy.device_policy.name
  target = aws_iot_certificate.esp32_fleet.arn
}

resource "aws_iot_thing_principal_attachment" "esp32_fleet" {
  thing     = aws_iot_thing.esp32_fleet.name
  principal = aws_iot_certificate.esp32_fleet.arn
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
