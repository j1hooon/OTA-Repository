#!/usr/bin/env bash
# Route 53 DNS 절체 시간 측정 v3 (하트비트 중단 -> DNS 가 DR EIP 로 바뀌기까지, 복구 후 PRIMARY 로 복귀까지)
#
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
OUTDIR="${OUTDIR:-docs/evidence/dns-failover}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/summary.csv"
echo "run,fault,alarm_s,failover_auth_s,failover_res_s,failback_auth_s,failback_res_s,valid" > "$CSV"

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

for run in $(seq 1 "$RUNS"); do
  LOG="$OUTDIR/run${run}.log"; : > "$LOG"
  { echo "=== run $run  fault=$FAULT  $(date '+%F %T')  git=$(git rev-parse --short HEAD 2>/dev/null)"
    echo "params: NAME=$NAME AUTH_NS=$AUTH_NS PRIMARY=$PRIMARY_IP DR=$DR_IP POLL=$POLL MAX_WAIT=$MAX_WAIT"; } | tee -a "$LOG"
  if [ "$(ip_ans "$AUTH_NS")" != "$PRIMARY_IP" ] || { [ "$(alarm_state)" != "OK" ] && [ "$(alarm_state)" != "-" ]; }; then
    echo "중단: 시작 시점에 PRIMARY 응답이 아니거나 알람이 OK 가 아님. 안정화 후 다시 실행하세요." | tee -a "$LOG"; exit 1
  fi
  T_ALARM=""; VALID=1
  echo "$(date +%H:%M:%S) [FAULT:$FAULT] 장애 주입" | tee -a "$LOG"
  T0=$(now); inject
  wait_for "$DR_IP" "$T0" "$LOG" 1; rc=$?
  FA="${T_AUTH:-timeout}"; FR="${T_RES:-timeout}"; AL="${T_ALARM:-none}"
  [ $rc -eq 2 ] && VALID=0
  echo "$(date +%H:%M:%S) [RESTORE] 복구" | tee -a "$LOG"
  T1=$(now); restore
  BA="-"; BR="-"
  if [ $VALID -eq 1 ]; then
    wait_for "$PRIMARY_IP" "$T1" "$LOG" 0; rc=$?
    BA="${T_AUTH:-timeout}"; BR="${T_RES:-timeout}"; [ $rc -eq 2 ] && VALID=0
  fi
  echo "$run,$FAULT,$AL,$FA,$FR,$BA,$BR,$VALID" >> "$CSV"
  echo "run $run: alarm=${AL}s | failover auth=${FA}s res=${FR}s | failback auth=${BA}s res=${BR}s | valid=$VALID" | tee -a "$LOG"
  echo "서비스 상태: $(systemctl is-active "$SERVICE" 2>/dev/null)" | tee -a "$LOG"
  [ "$run" -lt "$RUNS" ] && sleep 60
done
echo; echo "== 결과: $CSV =="; cat "$CSV"
