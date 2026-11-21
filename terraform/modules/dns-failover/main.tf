# 1. Route 53 호스팅 영역 생성 (도메인은 가비아 등록, 네임서버를 이 존으로 위임)
#    domain_name 에 위임할 이름을 넣는다(서브도메인 위임이면 "ota.j1hoon.store").
#    주의: 존을 destroy 후 다시 만들면 네임서버 4개가 바뀌어 가비아를 다시 설정해야 한다.
# 재사용 위임 세트: 존을 destroy/재생성해도 네임서버 4개가 바뀌지 않는다(가비아 재설정 불필요).
resource "aws_route53_delegation_set" "main" {
  reference_name = "${var.environment}-ota"
}

resource "aws_route53_zone" "main" {
  name              = var.domain_name
  comment           = "${var.environment} OTA DNS failover zone"
  delegation_set_id = aws_route53_delegation_set.main.id
}

# 2. CloudWatch Metric Alarm (도쿄 리전 ap-northeast-1 생성)
# - 비용 최적화: period = 60 (Standard Resolution, AWS 프리티어 무료 대상)
# - [확장 계획]: 상용 운영 환경에서 RTO를 90초 이내로 단축해야 할 경우,
#   period = 30 (High-Resolution Alarm, $0.30/월)으로 변경 가능
resource "aws_cloudwatch_metric_alarm" "onprem_heartbeat" {
  alarm_name                = "${var.environment}-onprem-heartbeat-alarm"
  comparison_operator       = "LessThanThreshold"
  evaluation_periods        = 3
  period                    = 60
  metric_name               = "OnPremHeartbeat"
  namespace                 = "OTA/HybridDR"
  statistic                 = "Sum"
  threshold                 = 1
  treat_missing_data        = "breaching" # 하트비트 단절(Missing) 시 ALARM 상태로 전환
  alarm_description         = "Trigger Route 53 DNS Failover to Tokyo DR when On-Premise L7 health heartbeat is missing"
  insufficient_data_actions = []
}

# 3. Route 53 Health Check (도쿄 리전 CloudWatch Alarm 감시)
resource "aws_route53_health_check" "onprem_primary_hc" {
  type                    = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name   = aws_cloudwatch_metric_alarm.onprem_heartbeat.alarm_name
  cloudwatch_alarm_region = var.aws_region

  # 하트비트가 끊기면 지표 데이터가 없어 INSUFFICIENT_DATA 가 된다. 측정으로 확인: 데이터 없음으로 생긴
  # ALARM 은 Route 53 이 비정상으로 보지 않으므로(Healthy 일 때 18분 이상 ALARM 에도 절체 없음),
  # 데이터 없음 자체를 Unhealthy 로 취급해 절체한다.
  # 주의: 첫 apply 직후(하트비트 에이전트 가동 전)에는 DR 로 넘어갈 수 있으니 에이전트를 먼저/바로 가동한다.
  insufficient_data_health_status = "Unhealthy"

  tags = {
    Name = "${var.environment}-onprem-hc"
  }
}

# 4. Route 53 Failover Record #1: PRIMARY (평상시 온프레미스로 라우팅)
resource "aws_route53_record" "ota_primary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.ota_subdomain
  type    = "A"
  ttl     = 60

  failover_routing_policy {
    type = "PRIMARY"
  }

  set_identifier  = "Primary-OnPremise"
  health_check_id = aws_route53_health_check.onprem_primary_hc.id
  records         = [var.onprem_public_ip]
}

# 5. Route 53 Failover Record #2: SECONDARY (장애 시 도쿄 DR K3s EIP로 라우팅)
resource "aws_route53_record" "ota_secondary" {
  zone_id = aws_route53_zone.main.zone_id
  name    = var.ota_subdomain
  type    = "A"
  ttl     = 60

  failover_routing_policy {
    type = "SECONDARY"
  }

  set_identifier = "Secondary-Tokyo-DR"
  records        = [var.dr_k3s_public_ip]
}

# 6. 로컬 하트비트 에이전트 전용 최소 권한 IAM User (cloudwatch:PutMetricData 전용)
resource "aws_iam_user" "heartbeat_sender" {
  name = "${var.environment}-heartbeat-sender"
}

resource "aws_iam_access_key" "heartbeat_sender" {
  user = aws_iam_user.heartbeat_sender.name
}

data "aws_iam_policy_document" "heartbeat_policy" {
  statement {
    sid       = "AllowPutHeartbeatMetricOnly"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["OTA/HybridDR"]
    }
  }
}

resource "aws_iam_user_policy" "heartbeat_sender" {
  name   = "${var.environment}-heartbeat-policy"
  user   = aws_iam_user.heartbeat_sender.name
  policy = data.aws_iam_policy_document.heartbeat_policy.json
}
