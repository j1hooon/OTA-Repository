#!/bin/bash
set -u

LOCAL_OTA_URL="http://172.16.10.1:8000/ota/check?device_id=hc-probe&current_version=1.0.0"
CW_NAMESPACE="OTA/HybridDR"
CW_METRIC="OnPremHeartbeat"
AWS_REGION="ap-northeast-1"

echo "[INFO] Starting On-Premise L7 Heartbeat Agent for Route 53 Failover..."

while true; do
  # 로컬 HAProxy -> K3s FastAPI -> DB/Redis 파이프라인이 HTTP 200을 반환할 때만 생존 보고
  RESPONSE=$(curl -sf --max-time 5 "${LOCAL_OTA_URL}" || true)
  if echo "${RESPONSE}" | grep -q '"status"'; then
    aws cloudwatch put-metric-data \
      --region "${AWS_REGION}" \
      --namespace "${CW_NAMESPACE}" \
      --metric-name "${CW_METRIC}" \
      --value 1
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [OK] Local OTA API healthy. Heartbeat(1) sent to CloudWatch."
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] Local OTA API UNHEALTHY! Skipping heartbeat to trigger Tokyo DR failover."
  fi
  sleep 30
done
