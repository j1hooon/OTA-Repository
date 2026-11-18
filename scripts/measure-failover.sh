#!/bin/bash
# HAProxy Active -> Standby 절체(RTO)와 자동 복귀(failback) 시간을 반복 측정한다. (mgmt 에서 실행)
#
# 방식: active 노드의 NodePort(30080)를 iptables raw 테이블에서 DROP 하여 "서비스 장애"를 만들고,
#       mgmt 에서 0.1초 간격으로 HAProxy(:8000)/health 를 호출하며 응답한 클러스터와 시각을 기록한다.
#       장애는 FAIL_SECS 후 자동 해제되며, 스크립트가 중단돼도 trap 으로 규칙을 제거한다.
#
# 사용:   RUNS=5 FAIL_SECS=15 ./scripts/measure-failover.sh
#         ./scripts/measure-failover.sh --analyze <로그파일> <t_inject_ms> <t_restore_ms>   (분석만 수행)
#
# 지표 (모두 클라이언트(=mgmt)에서 관측한 값, 단위 ms):
#   detect_ms   장애 주입 ~ 첫 실패 응답
#   downtime_ms 첫 실패 응답 ~ standby 첫 정상 응답 (사용자가 체감한 서비스 중단 구간)
#   rto_ms      장애 주입 ~ standby 첫 정상 응답
#   failback_ms 장애 해제 ~ active 첫 정상 응답
#   failed_reqs 주입 ~ standby 첫 정상 응답 사이의 실패 요청 수
# 주의: 주입/해제 시각은 ssh 명령이 반환된 시점이라 실제 적용 시각과 수십 ms 차이가 날 수 있다.
set -uo pipefail

BASE_URL="${BASE_URL:-http://172.16.10.1:8000}"
ACTIVE_SSH="${ACTIVE_SSH:-ubuntu@172.16.100.1}"
NODEPORT="${NODEPORT:-30080}"
RUNS="${RUNS:-5}"
FAIL_SECS="${FAIL_SECS:-15}"
POLL_INTERVAL="${POLL_INTERVAL:-0.1}"
OUTDIR="${OUTDIR:-./failover-results}"

now_ms() { date +%s%3N; }

# 로그 한 줄 형식: <epoch_ms> <http_code> <cluster|->
analyze() {  # $1=log $2=t_inject $3=t_restore  -> "detect downtime rto failback failed"
  awk -v ti="$2" -v tr="$3" '
    $1 >= ti && !sb && $2 != 200 { fails++; if (!ff) ff = $1 }
    $1 >= ti && !sb && $2 == 200 && $3 == "standby" { sb = $1 }
    $1 >= tr && !fb && $2 == 200 && $3 == "active"  { fb = $1 }
    END {
      if (!sb || !fb) { print "NA NA NA NA " fails+0; exit }
      det = ff ? ff - ti : 0
      down = ff ? sb - ff : 0
      printf "%d %d %d %d %d\n", det, down, sb - ti, fb - tr, fails + 0
    }' "$1"
}

median() { sort -n | awk '{a[NR]=$1} END{ if(!NR){print "-"; exit} print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2 }'; }

if [ "${1:-}" = "--analyze" ]; then
  analyze "$2" "$3" "$4"
  exit 0
fi

inject()  { ssh -o BatchMode=yes "$ACTIVE_SSH" "sudo iptables -t raw -C PREROUTING -p tcp --dport $NODEPORT -j DROP 2>/dev/null || sudo iptables -t raw -I PREROUTING -p tcp --dport $NODEPORT -j DROP"; }
restore() { ssh -o BatchMode=yes "$ACTIVE_SSH" "while sudo iptables -t raw -D PREROUTING -p tcp --dport $NODEPORT -j DROP 2>/dev/null; do :; done"; }

POLLER_PID=""
cleanup() {
  [ -n "$POLLER_PID" ] && kill "$POLLER_PID" 2>/dev/null
  restore >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

poll() {  # $1=logfile
  local t body code cl
  while :; do
    t=$(now_ms)
    body=$(curl -s -m 1 -w ' %{http_code}' "$BASE_URL/health" 2>/dev/null) || body=" 000"
    code=${body##* }
    cl=$(printf '%s' "$body" | grep -oE '"cluster": *"[a-z]+"' | head -1 | cut -d'"' -f4)
    echo "$t $code ${cl:--}" >> "$1"
    sleep "$POLL_INTERVAL"
  done
}

wait_stable_active() {
  local ok=0 i out
  for i in $(seq 1 90); do
    out=$(curl -s -m 1 "$BASE_URL/health" 2>/dev/null)
    if printf '%s' "$out" | grep -Eq '"cluster": *"active"'; then ok=$((ok+1)); else ok=0; fi
    [ "$ok" -ge 5 ] && return 0
    sleep 1
  done
  return 1
}

# 사전 점검
ssh -o BatchMode=yes "$ACTIVE_SSH" 'sudo -n true' >/dev/null 2>&1 || { echo "[FAIL] $ACTIVE_SSH 에 키 로그인/sudo 가 안 됩니다"; exit 1; }
mkdir -p "$OUTDIR"
CSV="$OUTDIR/summary.csv"
echo "run,detect_ms,downtime_ms,rto_ms,failback_ms,failed_reqs" > "$CSV"
echo "[INFO] 측정 시작: RUNS=$RUNS FAIL_SECS=${FAIL_SECS}s 대상=$BASE_URL (측정 중에는 Jenkins 빌드를 돌리지 마세요)"

for i in $(seq 1 "$RUNS"); do
  restore >/dev/null 2>&1
  echo "[RUN $i/$RUNS] active 정상 상태 대기..."
  wait_stable_active || { echo "[FAIL] active 가 정상 상태로 돌아오지 않습니다"; exit 1; }

  LOG="$OUTDIR/run$i.log"; : > "$LOG"
  poll "$LOG" & POLLER_PID=$!
  sleep 3

  inject;  T_INJ=$(now_ms)
  echo "[RUN $i/$RUNS] 장애 주입 (active NodePort DROP, ${FAIL_SECS}s)"
  sleep "$FAIL_SECS"
  restore; T_RES=$(now_ms)
  echo "[RUN $i/$RUNS] 장애 해제, 자동 복귀 대기..."

  for s in $(seq 1 90); do
    [ "$(tail -n 5 "$LOG" | awk '$2==200 && $3=="active"' | wc -l)" -eq 5 ] && break
    sleep 1
  done
  kill "$POLLER_PID" 2>/dev/null; wait "$POLLER_PID" 2>/dev/null; POLLER_PID=""

  read -r DET DOWN RTO FB FAILS <<< "$(analyze "$LOG" "$T_INJ" "$T_RES")"
  echo "$i,$DET,$DOWN,$RTO,$FB,$FAILS" >> "$CSV"
  echo "[RUN $i/$RUNS] detect=${DET}ms downtime=${DOWN}ms rto=${RTO}ms failback=${FB}ms failed_reqs=${FAILS}"
  sleep 5
done

echo
echo "================ 결과 요약 (${RUNS}회, 단위 ms) ================"
printf "%-12s %8s %8s %8s\n" 지표 최소 중앙값 최대
for col in 2:detect 3:downtime 4:rto 5:failback; do
  n=${col%%:*}; name=${col##*:}
  vals=$(tail -n +2 "$CSV" | cut -d, -f"$n" | grep -E '^[0-9]+$')
  if [ -z "$vals" ]; then printf "%-12s %8s %8s %8s\n" "$name" - - -; continue; fi
  printf "%-12s %8s %8s %8s\n" "$name" "$(echo "$vals" | sort -n | head -1)" "$(echo "$vals" | median)" "$(echo "$vals" | sort -n | tail -1)"
done
echo "상세: $CSV, $OUTDIR/run*.log"
