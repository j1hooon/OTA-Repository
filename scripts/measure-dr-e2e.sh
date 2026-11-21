#!/usr/bin/env bash
# DR 종단(E2E) 테스트: 하트비트 중단 -> DNS 가 DR 로 전환 -> 그 DNS 응답으로 실제 요청이 DR 에서 처리되는지 확인
# (DNS 응답만 보는 measure-dns-failover.sh 와 달리, 전환 후 /ota/check, /ota/report 를 DR 로 보낸다)
#
# 추가 환경변수: REQS=10 (전환 후 보낼 /ota/check 횟수), DEVICE=ota-dr-tokyo-esp32-device-01
# 참고: 온프레미스(PRIMARY_IP)는 이 랩에서 외부 도달이 불가능하므로 복귀 후 트래픽 검증은 하지 않고 DNS 복귀만 본다.
# 기존 사용법 (mgmt 에서, 저장소 루트):
# 사용 (mgmt 에서, 저장소 루트):
#   DR_IP=$(terraform -chdir=terraform output -raw dr_k3s_public_ip) PRIMARY_IP=<ONPREM_PUBLIC_IP> \
#   AUTH_NS=ns-1060.awsdns-04.org RUNS=3 ./scripts/measure-dns-failover.sh
#
# 측정값(초, 장애 주입 시각 t0 기준):
#   alarm_s        : 알람이 OK 가 아닌 상태가 되기까지 (aws CLI 가 있을 때)
#   failover_auth  : Route 53 권한 서버가 DR IP 로 응답하기 시작 (캐시 영향 없음)
#   failover_res   : 공개 리졸버(8.8.8.8)가 DR IP 로 응답 (클라이언트 체감, TTL 포함)
#   failback_*     : 복구 시각 기준 PRIMARY 로 복귀
#   valid          : 1=정상, 0=무효(시계 점프 = VM 일시정지/절전 의심)
# FAULT=agent(기본) : 하트비트 서비스 중단 / FAULT=l7 : mgmt HAProxy 컨테이너 중단(에이전트는 살아 있고 /health 만 실패)
set -u
NAME="${NAME:-ota.j1hoon.store}"
AUTH_NS="${AUTH_NS:?AUTH_NS 필요 (예: ns-1060.awsdns-04.org)}"
PRIMARY_IP="${PRIMARY_IP:?PRIMARY_IP 필요}"
DR_IP="${DR_IP:?DR_IP 필요}"
RESOLVER="${RESOLVER:-8.8.8.8}"
RUNS="${RUNS:-1}"
POLL="${POLL:-3}"
MAX_WAIT="${MAX_WAIT:-1800}"
SERVICE="${SERVICE:-ota-heartbeat}"
FAULT="${FAULT:-agent}"
HAPROXY_CONTAINER="${HAPROXY_CONTAINER:-ota-haproxy}"
REGION="${REGION:-ap-northeast-1}"
ALARM="${ALARM:-ota-dr-tokyo-onprem-heartbeat-alarm}"
ALARM_EVERY="${ALARM_EVERY:-5}"     # N 번 폴링마다 알람 상태 조회
STABLE="${STABLE:-3}"                # 연속 N 번 목표 값이어야 확정
JUMP="${JUMP:-60}"                  # 폴링 사이 이 초 이상 건너뛰면 무효(절전/일시정지)
OUTDIR="${OUTDIR:-docs/evidence/dr-e2e}"
REQS="${REQS:-10}"
DEVICE="${DEVICE:-ota-dr-tokyo-esp32-device-01}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/summary.csv"
echo "run,fault,alarm_s,failover_auth_s,failover_res_s,dr_first_ok_s,dr_ok,dr_total,report_result,failback_auth_s,valid" > "$CSV"

now() { if [ -n "${NOW_CMD:-}" ]; then eval "$NOW_CMD"; else date +%s; fi; }
ip_ans() { local o; o=$(dig +short +time=2 +tries=1 "$NAME" "@$1" 2>/dev/null | head -1)
           [[ "$o" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$o" || echo "?"; }
alarm_state() { command -v aws >/dev/null 2>&1 || { echo "-"; return; }
                timeout 8 aws cloudwatch describe-alarms --region "$REGION" --alarm-names "$ALARM" \
                  --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "?"; }

inject()  { if [ "$FAULT" = l7 ]; then sudo docker stop "$HAPROXY_CONTAINER" >/dev/null; else sudo systemctl stop "$SERVICE"; fi; }
restore() { sudo systemctl start "$SERVICE" 2>/dev/null
            [ "$FAULT" = l7 ] && sudo docker start "$HAPROXY_CONTAINER" >/dev/null 2>&1; return 0; }
trap restore EXIT INT TERM

# target 을 두 서버가 모두 답할 때까지 폴링. 반환 0=성공 1=시간초과 2=무효(시계 점프)
wait_for() {  # $1=target $2=t0 $3=log $4=track_alarm(0/1)
  local target="$1" t0="$2" log="$3" track="$4" a r st="-" cur prev el i=0 ca=0 cr=0 fa=0 fr=0
  T_AUTH=""; T_RES=""; prev=$(now)
  while :; do
    cur=$(now); el=$(( cur - t0 ))
    if [ $(( cur - prev )) -gt "$JUMP" ]; then
      echo "$(date +%H:%M:%S) [INVALID] 폴링 사이 $(( cur - prev ))초 점프: VM 일시정지/절전 의심. 이 회차는 무효." | tee -a "$log"
      return 2
    fi
    prev=$cur
    a=$(ip_ans "$AUTH_NS"); r=$(ip_ans "$RESOLVER")
    [ $(( i % ALARM_EVERY )) -eq 0 ] && st=$(alarm_state); i=$((i+1))
    if [ "$track" = 1 ] && [ -z "$T_ALARM" ] && [ "$st" != "OK" ] && [ "$st" != "-" ] && [ "$st" != "?" ]; then T_ALARM=$el; fi
    echo "$(date +%H:%M:%S) +${el}s auth=$a res=$r alarm=$st" | tee -a "$log"
    # 한 번 목표 값이 나왔다고 성공으로 치지 않는다: 공개 리졸버는 캐시 노드가 여럿이라 응답이 섞인다.
    # STABLE 번 연속으로 목표 값일 때만 확정하고, 시각은 그 연속 구간의 첫 응답으로 기록한다.
    if [ "$a" = "$target" ]; then ca=$((ca+1)); [ "$ca" -eq 1 ] && fa=$el; else ca=0; fi
    if [ "$r" = "$target" ]; then cr=$((cr+1)); [ "$cr" -eq 1 ] && fr=$el; else cr=0; fi
    [ -z "$T_AUTH" ] && [ "$ca" -ge "$STABLE" ] && T_AUTH=$fa
    [ -z "$T_RES" ]  && [ "$cr" -ge "$STABLE" ] && T_RES=$fr
    [ -n "$T_AUTH" ] && [ -n "$T_RES" ] && return 0
    [ "$el" -ge "$MAX_WAIT" ] && return 1
    sleep "$POLL"
  done
}


# DNS 리졸버 응답 IP 로 NAME 을 직접 접속(--resolve): 실제 클라이언트가 보는 경로와 같다.
drreq() {  # $1=ip  -> "cluster" 또는 "-"
  curl -s --max-time 5 --resolve "$NAME:80:$1" "http://$NAME/ota/check?device_id=$DEVICE&current_version=0.0.0" 2>/dev/null \
   | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("handled_by_cluster","-"))
except Exception: print("-")'
}
drreport() {
  curl -s --max-time 5 --resolve "$NAME:80:$1" -X POST "http://$NAME/ota/report" -H 'Content-Type: application/json' \
   -d "{\"device_id\":\"$DEVICE\",\"target_version\":\"e2e\",\"status\":\"SUCCESS\",\"duration_ms\":1,\"rssi\":-50}" 2>/dev/null \
   | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("result","-"))
except Exception: print("-")'
}

for run in $(seq 1 "$RUNS"); do
  LOG="$OUTDIR/run${run}.log"; : > "$LOG"
  { echo "=== E2E run $run  fault=$FAULT  $(date '+%F %T')  git=$(git rev-parse --short HEAD 2>/dev/null)"
    echo "params: NAME=$NAME AUTH_NS=$AUTH_NS PRIMARY=$PRIMARY_IP DR=$DR_IP REQS=$REQS"; } | tee -a "$LOG"
  if [ "$(ip_ans "$AUTH_NS")" != "$PRIMARY_IP" ] || { [ "$(alarm_state)" != "OK" ] && [ "$(alarm_state)" != "-" ]; }; then
    echo "중단: 시작 시점에 PRIMARY 응답이 아니거나 알람이 OK 가 아님." | tee -a "$LOG"; exit 1
  fi
  if [ "$(drreq "$DR_IP")" != "dr" ]; then
    echo "중단: DR 이 직접 호출에도 응답하지 않음 (http://$DR_IP/ota/check). DR 배포를 먼저 확인하세요." | tee -a "$LOG"; exit 1
  fi
  T_ALARM=""; VALID=1; OK=0; TOTAL=0; REP="-"; FIRST="-"
  echo "$(date +%H:%M:%S) [FAULT:$FAULT] 장애 주입" | tee -a "$LOG"
  T0=$(now); inject
  wait_for "$DR_IP" "$T0" "$LOG" 1; rc=$?
  FA="${T_AUTH:-timeout}"; FR="${T_RES:-timeout}"; AL="${T_ALARM:-none}"
  [ $rc -eq 2 ] && VALID=0
  if [ $rc -eq 0 ]; then
    # 전환 확정 직후: 리졸버가 알려주는 IP 로 요청 REQS 번 + 보고 1번
    RIP=$(ip_ans "$RESOLVER"); echo "$(date +%H:%M:%S) [E2E] resolver($RESOLVER) 응답 IP=$RIP -> 요청 시작" | tee -a "$LOG"
    for k in $(seq 1 "$REQS"); do
      c=$(drreq "$RIP"); TOTAL=$((TOTAL+1))
      if [ "$c" = dr ]; then OK=$((OK+1)); [ "$FIRST" = "-" ] && FIRST=$(( $(now) - T0 )); fi
      echo "$(date +%H:%M:%S) check#$k handled_by_cluster=$c" | tee -a "$LOG"; sleep 1
    done
    REP=$(drreport "$RIP"); echo "$(date +%H:%M:%S) report result=$REP" | tee -a "$LOG"
  fi
  echo "$(date +%H:%M:%S) [RESTORE] 복구" | tee -a "$LOG"
  T1=$(now); restore
  BA="-"
  if [ $VALID -eq 1 ]; then wait_for "$PRIMARY_IP" "$T1" "$LOG" 0; rc=$?; BA="${T_AUTH:-timeout}"; [ $rc -eq 2 ] && VALID=0; fi
  echo "$run,$FAULT,$AL,$FA,$FR,$FIRST,$OK,$TOTAL,$REP,$BA,$VALID" >> "$CSV"
  echo "run $run: dns auth=${FA}s res=${FR}s | DR 첫 정상응답=${FIRST}s | check ${OK}/${TOTAL} dr | report=$REP | failback auth=${BA}s | valid=$VALID" | tee -a "$LOG"
  echo "서비스 상태: $(systemctl is-active "$SERVICE" 2>/dev/null)" | tee -a "$LOG"
  [ "$run" -lt "$RUNS" ] && sleep 60
done
echo; echo "== 결과: $CSV =="; cat "$CSV"
