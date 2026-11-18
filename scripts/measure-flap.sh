#!/bin/bash
# 평상시 오탐(flap) 점검: 장애를 주입하지 않고 일정 시간 부하를 주면서,
# HAProxy 가 정상 서버를 불필요하게 DOWN 으로 돌리는지(오탐)와 실패 요청이 있는지 센다. (mgmt 에서 실행)
# 헬스체크 간격(inter)을 줄여 RTO 를 낮출수록 오탐 위험이 커지므로, 튜닝값의 안전성 근거로 쓴다.
#
# 사용: DURATION=300 ./scripts/measure-flap.sh        (Jenkins 빌드 중에 돌리면 부하 상황의 점검이 된다)
# 합격 기준: 실패 요청 0건, DOWN 전환 0회
set -uo pipefail
BASE_URL="${BASE_URL:-http://172.16.10.1:8000}"
DURATION="${DURATION:-300}"
POLL_INTERVAL="${POLL_INTERVAL:-0.1}"
CONTAINER="${CONTAINER:-ota-haproxy}"

LOG=$(mktemp)
trap 'rm -f "$LOG"' EXIT
END=$(( $(date +%s) + DURATION ))
echo "[INFO] ${DURATION}초 동안 ${POLL_INTERVAL}초 간격으로 $BASE_URL/health 호출 (장애 주입 없음)"
while [ "$(date +%s)" -lt "$END" ]; do
  ( code=$(curl -s -o /dev/null -m 1 -w '%{http_code}' "$BASE_URL/health" 2>/dev/null) || code=000
    echo "$code" >> "$LOG" ) &
  sleep "$POLL_INTERVAL"
done
wait

TOTAL=$(wc -l < "$LOG")
BAD=$(grep -vc '^200$' "$LOG" || true)
if command -v docker >/dev/null 2>&1 && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  DOWNS=$(docker logs --since "$((DURATION + 5))s" "$CONTAINER" 2>&1 | grep -c '^Server .* is DOWN' || true)
else
  DOWNS="n/a(docker 없음)"
fi
echo "================ 오탐 점검 결과 ================"
echo "총 요청 ${TOTAL}건 / 실패 ${BAD}건 / HAProxy DOWN 전환 ${DOWNS}회"
if ! [[ "$DOWNS" =~ ^[0-9]+$ ]]; then
  if [ "$BAD" = "0" ]; then echo "[INFO] HAProxy 로그를 읽을 수 없어 요청 결과만 판정: 실패 요청 없음 (mgmt 에서 실행하면 DOWN 전환도 집계됨)"; else echo "[CHECK] 실패 요청이 있습니다"; fi
elif [ "$BAD" = "0" ] && [ "$DOWNS" = "0" ]; then
  echo "[PASS] 오탐 없음"
else
  echo "[CHECK] 실패 또는 DOWN 전환이 있습니다 -> 이 inter 값은 너무 공격적일 수 있음"
fi
