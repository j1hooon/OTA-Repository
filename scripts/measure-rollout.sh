#!/usr/bin/env bash
# API 롤아웃 시간 측정 (mgmt 에서 실행)
#
#   scripts/measure-rollout.sh                       # standby 클러스터, 5회
#   CTX=standby RUNS=10 OUTDIR=docs/evidence/rollout ./scripts/measure-rollout.sh
#
# 정의: `kubectl rollout restart` 를 실행한 시각부터 `kubectl rollout status` 가 성공(모든 새 파드 Ready,
#       기존 파드 종료)을 반환한 시각까지의 벽시계 시간(초). 이미지는 노드에 이미 있는 상태(warm)다.
#       장애 주입이 없는 측정이다. 트래픽 영향은 보지 않는다(maxUnavailable 0 설정에 의존).
#
# 안전장치:
#   - 기본 대상은 standby 다. active 는 FORCE=1 을 줘야 한다(서비스 중인 파드를 교체하므로).
#   - Ctrl+C 로 즉시 종료된다(복구할 장애가 없다).
#
# 환경 변수: CTX(standby) NS(default) APP(ota-api-server) RUNS(5) TIMEOUT(180, 초) OUTDIR(docs/evidence/rollout)
set -u
CTX=${CTX:-standby}; NS=${NS:-default}; APP=${APP:-ota-api-server}
RUNS=${RUNS:-5}; TIMEOUT=${TIMEOUT:-180}; OUTDIR=${OUTDIR:-docs/evidence/rollout}
trap 'echo; echo "중단됨"; exit 130' INT TERM

if [ "$CTX" = "active" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "거부: CTX=active 는 서비스 중인 클러스터입니다. 정말 필요하면 FORCE=1 을 지정하세요." >&2; exit 2
fi
K=(kubectl --context="$CTX" -n "$NS")
mkdir -p "$OUTDIR"
CSV="$OUTDIR/summary.csv"
GIT=$(git rev-parse --short HEAD 2>/dev/null || echo na)
IMAGE=$("${K[@]}" get deploy "$APP" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) \
  || { echo "중단: $CTX 에서 deploy/$APP 를 읽지 못했습니다." >&2; exit 1; }
SURGE=$("${K[@]}" get deploy "$APP" -o jsonpath='{.spec.strategy.rollingUpdate.maxSurge}/{.spec.strategy.rollingUpdate.maxUnavailable}')
REPL=$("${K[@]}" get deploy "$APP" -o jsonpath='{.spec.replicas}')

echo "=== rollout 측정  ctx=$CTX deploy=$APP replicas=$REPL maxSurge/maxUnavailable=$SURGE git=$GIT $(date '+%F %T')"
echo "image=$IMAGE runs=$RUNS timeout=${TIMEOUT}s"
[ -s "$CSV" ] || echo "run,started_at,ctx,git,image,replicas,rollout_s,ready_replicas,valid" > "$CSV"

secs=()
for i in $(seq 1 "$RUNS"); do
  # 이전 롤아웃이 완전히 끝나고 안정된 뒤에 시작
  "${K[@]}" rollout status "deploy/$APP" --timeout="${TIMEOUT}s" >/dev/null 2>&1 || { echo "run $i: 시작 전 상태 불안정 -> 중단"; exit 1; }
  sleep 5
  START=$(date '+%F %T'); T0=$(date +%s%N)
  "${K[@]}" rollout restart "deploy/$APP" >/dev/null
  "${K[@]}" rollout status "deploy/$APP" --timeout="${TIMEOUT}s" >/dev/null 2>&1; RC=$?
  T1=$(date +%s%N)
  S=$(awk -v a="$T0" -v b="$T1" 'BEGIN{printf "%.1f",(b-a)/1e9}')
  READY=$("${K[@]}" get deploy "$APP" -o jsonpath='{.status.readyReplicas}')
  VALID=1; [ "$RC" -eq 0 ] && [ "${READY:-0}" = "$REPL" ] || VALID=0
  echo "$i,$START,$CTX,$GIT,$IMAGE,$REPL,$S,${READY:-0},$VALID" >> "$CSV"
  echo "run $i: ${S}s ready=${READY:-0}/$REPL valid=$VALID"
  [ "$VALID" -eq 1 ] && secs+=("$S")
done

if [ "${#secs[@]}" -gt 0 ]; then
  sorted=($(printf '%s\n' "${secs[@]}" | sort -n)); n=${#sorted[@]}
  MED=$(awk -v n="$n" -v s="${sorted[*]}" 'BEGIN{split(s,a," "); if(n%2) printf "%.1f",a[(n+1)/2]; else printf "%.1f",(a[n/2]+a[n/2+1])/2}')
  echo "유효 ${n}회  중앙값=${MED}s  범위=${sorted[0]}~${sorted[$((n-1))]}s"
fi
echo "기록: $CSV"
