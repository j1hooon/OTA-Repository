# ---------------------------------------------------------------------------
# 기기 상태(ota/status/<thing>) 수집 파이프라인:  IoT Rule -> SQS(+DLQ) -> FastAPI 소비자 -> PostgreSQL
# 내부망 K3s 를 외부에 노출하지 않고, FastAPI 가 AWS 의 큐를 끌어오는(pull) 구조.
# FastAPI 용 IAM User 는 새로 만들지 않고 기존 사용자(ota_api_publisher)에 정책만 추가한다(키 변경 없음).
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "device_status_dlq" {
  name                      = "${var.environment}-device-status-dlq"
  message_retention_seconds = 1209600 # 14일
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "device_status" {
  name                       = "${var.environment}-device-status"
  message_retention_seconds  = 345600 # 4일: K3s 절체/점검 중에도 상태 메시지 보관
  receive_wait_time_seconds  = 20     # 롱폴링
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.device_status_dlq.arn
    maxReceiveCount     = 5
  })
}

# IoT Rule 이 큐에 쓰기 위한 역할 (이 큐에 SendMessage 만 허용)
data "aws_iam_policy_document" "iot_rule_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["iot.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "iot_rule_sqs" {
  name               = "${var.environment}-iot-rule-sqs"
  assume_role_policy = data.aws_iam_policy_document.iot_rule_assume.json
}

data "aws_iam_policy_document" "iot_rule_sqs_send" {
  statement {
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.device_status.arn]
  }
}

resource "aws_iam_role_policy" "iot_rule_sqs" {
  name   = "${var.environment}-iot-rule-sqs-send"
  role   = aws_iam_role.iot_rule_sqs.id
  policy = data.aws_iam_policy_document.iot_rule_sqs_send.json
}

# topic(3) = 토픽 경로의 세 번째 요소 = Thing 이름. 기기 정책이 "자기 이름 토픽에만 발행"을 강제하므로
# 페이로드 안의 이름이 아니라 토픽에서 뽑은 이름을 신뢰한다(위조 방지).
resource "aws_iot_topic_rule" "device_status" {
  name        = replace("${var.environment}_device_status", "-", "_")
  enabled     = true
  sql         = "SELECT *, topic(3) AS thing, timestamp() AS received_at FROM 'ota/status/+'"
  sql_version = "2016-03-23"

  sqs {
    queue_url  = aws_sqs_queue.device_status.url
    role_arn   = aws_iam_role.iot_rule_sqs.arn
    use_base64 = false
  }

  depends_on = [aws_iam_role_policy.iot_rule_sqs]
}

# FastAPI 용 기존 IAM User 에 '이 큐 읽기/삭제'만 추가 (access key 는 그대로)
data "aws_iam_policy_document" "ota_api_sqs_consume" {
  statement {
    sid = "AllowConsumeDeviceStatus"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
    ]
    resources = [aws_sqs_queue.device_status.arn]
  }
}

resource "aws_iam_user_policy" "ota_api_sqs_consume" {
  name   = "${var.environment}-fastapi-sqs-consume-policy"
  user   = aws_iam_user.ota_api_publisher.name
  policy = data.aws_iam_policy_document.ota_api_sqs_consume.json
}
