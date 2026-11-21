#!/usr/bin/env bash
# DNS 오탐(flap) 점검: 하트비트를 정상으로 켜 둔 채, 권한 서버 응답이 PRIMARY 에서 벗어나는지 일정 시간 감시한다.
# 'insufficient_data_health_status = Unhealthy' 설정은 지표 데이터가 잠깐 비어도 DR 로 절체할 수 있으므로
# 장시간 정상 운영 중 절체가 없어야 한다.
#
# 사용 (mgmt 에서, 저장소 루트):
#   AUTH_NS=ns-1060.awsdns-04.org PRIMARY_IP=<ONPREM_PUBLIC_IP> DURATION=7200 ./scripts/measure-dns-flap.sh
#
# 판정: PASS = PRIMARY 이탈 0건 + 하트비트 항상 active + 시계 점프 없음
#       CHECK = 이탈 있음(로그 확인) / INVALID = 시계 점프(절전 의심), 재측정 필요
set -u
NAME="${NAME:-ota.j1hoon.store}"
AUTH_NS="${AUTH_NS:?AUTH_NS 필요 (예: ns-1060.awsdns-04.org)}"
PRIMARY_IP="${PRIMARY_IP:?PRIMARY_IP 필요}"
DURATION="${DURATION:-3600}"
INTERVAL="${INTERVAL:-15}"
JUMP="${JUMP:-120}"
SERVICE="${SERVICE:-ota-heartbeat}"
OUTDIR="${OUTDIR:-docs/evidence/dns-failover}"
mkdir -p "$OUTDIR"; LOG="$OUTDIR/flap.log"
now() { if [ -n "${NOW_CMD:-}" ]; then eval "$NOW_CMD"; else date +%s; fi; }
ip_ans() { local o; o=$(dig +short +time=2 +tries=1 "$NAME" "@$AUTH_NS" 2>/dev/null | head -1)
           [[ "$o" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$o" || echo "?"; }

: > "$LOG"
echo "=== DNS flap check $(date '+%F %T') git=$(git rev-parse --short HEAD 2>/dev/null)" | tee -a "$LOG"
echo "params: NAME=$NAME AUTH_NS=$AUTH_NS PRIMARY=$PRIMARY_IP DURATION=${DURATION}s INTERVAL=${INTERVAL}s" | tee -a "$LOG"
start=$(now); prev=$start; samples=0; dev=0; unk=0; hbbad=0; invalid=0; lastprog=$start
while :; do
  cur=$(now)
  if [ $(( cur - prev )) -gt "$JUMP" ]; then
    echo "$(date +%H:%M:%S) [INVALID] 폴링 사이 $(( cur - prev ))초 점프: VM 일시정지/절전 의심" | tee -a "$LOG"; invalid=1; break
  fi
  prev=$cur
  [ $(( cur - start )) -ge "$DURATION" ] && break
  a=$(ip_ans); hb=$(systemctl is-active "$SERVICE" 2>/dev/null); samples=$((samples+1))
  if [ "$a" = "?" ]; then unk=$((unk+1)); echo "$(date +%H:%M:%S) [NOANSWER] 권한 서버 무응답/비정상 응답 (이탈로 세지 않음)" >> "$LOG"
  elif [ "$a" != "$PRIMARY_IP" ]; then dev=$((dev+1)); echo "$(date +%H:%M:%S) +$(( cur - start ))s [DEVIATION] answer=$a hb=$hb" | tee -a "$LOG"; fi
  [ "$hb" != "active" ] && { hbbad=$((hbbad+1)); echo "$(date +%H:%M:%S) [HEARTBEAT] service=$hb" | tee -a "$LOG"; }
  if [ $(( cur - lastprog )) -ge 600 ]; then lastprog=$cur; echo "$(date +%H:%M:%S) +$(( cur - start ))s 진행: 표본=$samples 이탈=$dev" | tee -a "$LOG"; fi
  sleep "$INTERVAL"
done
el=$(( $(now) - start ))
if   [ $invalid -eq 1 ]; then v="INVALID(시계 점프, 재측정 필요)"
elif [ $dev -eq 0 ] && [ $hbbad -eq 0 ]; then v="PASS"
else v="CHECK(이탈/하트비트 이상, 로그 확인)"; fi
echo "== 결과: ${el}s 동안 표본 $samples, PRIMARY 이탈 $dev, 무응답 $unk, 하트비트 비정상 $hbbad  => $v" | tee -a "$LOG"
