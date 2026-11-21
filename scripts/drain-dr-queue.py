#!/usr/bin/env python3
"""DR 보고 큐 반영기: DR Redis 의 ota:dr:report_queue -> 온프레미스 PostgreSQL(primary).

DR 동안 /ota/report 는 복제본(읽기 전용)에 쓸 수 없어 Redis 큐(AOF)에 쌓인다.
온프레미스가 복귀한 뒤 mgmt 에서 이 스크립트를 실행해 원본 DB 에 반영한다.

  python3 scripts/drain-dr-queue.py              # 반영
  DRY_RUN=1 python3 scripts/drain-dr-queue.py    # 읽기만 (쓰기/삭제 없음)

보장
  - 멱등: event_id(없으면 원문 sha256)로 UNIQUE 중복 방지 -> 중간에 끊겨도 다시 실행하면 된다.
  - 큐 삭제는 "모든 이벤트가 DB 에 반영(또는 dead-letter 로 이동)된 뒤" 반영한 개수만큼만 LTRIM.
    그동안 새로 들어온 이벤트(오른쪽 추가)는 건드리지 않는다.
  - 처리 못 하는 이벤트(예: status 값이 CHECK 위반)는 ota:dr:report_dead 로 옮겨 나머지를 막지 않는다.
  - completed_at 은 DR 에서 접수한 시각(queued_at)을 쓰고, devices.current_version 은 더 새로운 이벤트일 때만 갱신한다.

환경변수
  DR_CONTEXT=dr  REDIS_CONTAINER_DEPLOY=ota-redis  PG_CONTAINER=ota-postgres  PGPASSWORD(선택)
  REDIS_CMD / PSQL_CMD : 테스트용 명령 전체 덮어쓰기(공백 구분)
"""
import os, sys, json, hashlib, shlex, subprocess

QUEUE = os.environ.get("QUEUE", "ota:dr:report_queue")
DEAD = os.environ.get("DEAD", "ota:dr:report_dead")
DRY = os.environ.get("DRY_RUN") == "1"

def redis_base():
    if os.environ.get("REDIS_CMD"):
        return shlex.split(os.environ["REDIS_CMD"])
    ctx = os.environ.get("DR_CONTEXT", "dr")
    dep = os.environ.get("REDIS_DEPLOY", "ota-redis")
    return ["kubectl", f"--context={ctx}", "exec", "-i", f"deploy/{dep}", "--", "sh", "-c",
            'exec redis-cli -a "$REDIS_PASS" --no-auth-warning "$@"', "sh"]

def psql_base():
    if os.environ.get("PSQL_CMD"):
        return shlex.split(os.environ["PSQL_CMD"])
    c = os.environ.get("PG_CONTAINER", "ota-postgres")
    env = ["-e", f"PGPASSWORD={os.environ['PGPASSWORD']}"] if os.environ.get("PGPASSWORD") else []
    return ["docker", "exec", "-i", *env, c, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "ota_admin", "-d", "ota_db"]

def run(cmd, stdin=None, check=True):
    p = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    if check and p.returncode != 0:
        raise RuntimeError(f"{cmd[0]} rc={p.returncode}: {p.stderr.strip()[:300]}")
    return p

def rcli(*args, stdin=None, check=True):
    return run(redis_base() + list(args), stdin, check)

def psql(sql, *vars_, check=True):
    cmd = psql_base()
    for v in vars_: cmd += ["-v", v]
    return run(cmd + ["-tA"], stdin=sql, check=check)

MIGRATE = """
ALTER TABLE ota_deployment_history ADD COLUMN IF NOT EXISTS event_id TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS uq_ota_history_event_id ON ota_deployment_history(event_id);
"""

# devices -> history 는 한 문장(CTE)으로: 같은 트랜잭션이고 FK 는 문장 끝에서 검사된다.
APPLY = """
WITH e AS (SELECT :'ev'::jsonb AS j, :'eid'::text AS id),
ts AS (SELECT to_timestamp(COALESCE((j->>'queued_at')::bigint, extract(epoch from now())::bigint)) AS t FROM e),
d AS (
  INSERT INTO devices (device_id, current_version, updated_at)
  SELECT j->>'device_id', j->>'target_version', ts.t FROM e, ts
  ON CONFLICT (device_id) DO UPDATE
    SET current_version = EXCLUDED.current_version, updated_at = EXCLUDED.updated_at
    WHERE devices.updated_at < EXCLUDED.updated_at
  RETURNING 1),
h AS (
  INSERT INTO ota_deployment_history
    (device_id, target_version, status, duration_ms, handled_by_cluster, completed_at, event_id)
  SELECT j->>'device_id', j->>'target_version', j->>'status', (j->>'duration_ms')::int,
         COALESCE(j->>'handled_by_cluster','dr'), ts.t, e.id FROM e, ts
  ON CONFLICT (event_id) DO NOTHING
  RETURNING 1)
SELECT count(*) FROM h;
"""

def event_id(raw, ev):
    return ev.get("event_id") or "legacy-" + hashlib.sha256(raw.encode()).hexdigest()[:32]

def main():
    try:
        rec = psql("select pg_is_in_recovery();").stdout.strip()
    except RuntimeError as e:
        sys.exit(f"중단: PostgreSQL 에 접속하지 못함 ({e}). 컨테이너명/PGPASSWORD 를 확인하세요.")
    if rec != "f":
        sys.exit("중단: 대상 PostgreSQL 이 primary 가 아님(읽기 전용 복제본).")
    try:
        raw_list = [l for l in rcli("lrange", QUEUE, "0", "-1").stdout.split("\n") if l.strip()]
    except RuntimeError as e:
        sys.exit(f"중단: DR Redis 에 접속하지 못함 ({e}). DR 클러스터가 살아 있고 kubectl --context=dr 이 되는지 확인하세요.")
    n = len(raw_list)
    print(f"큐 {QUEUE}: {n}건" + (" (DRY_RUN: 쓰기/삭제 없음)" if DRY else ""))
    if n == 0 or DRY:
        for r in raw_list[:3]: print("  예:", r[:160])
        return
    psql(MIGRATE)
    ins = dup = dead = 0
    for raw in raw_list:
        try:
            ev = json.loads(raw)
            eid = event_id(raw, ev)
            out = psql(APPLY, f"ev={raw}", f"eid={eid}").stdout.strip()
            if out == "1": ins += 1
            else: dup += 1
        except Exception as e:
            dead += 1
            print(f"  [DEAD] {str(e)[:140]} :: {raw[:100]}", file=sys.stderr)
            rcli("-x", "rpush", DEAD, stdin=raw)
    # 전부 처리(반영/중복/dead-letter)된 뒤에만, 읽은 개수만큼 앞에서 제거
    rcli("ltrim", QUEUE, str(n), "-1")
    left = rcli("llen", QUEUE).stdout.strip()
    print(f"완료: 읽음 {n} = 신규 반영 {ins} + 중복 건너뜀 {dup} + dead-letter {dead} | 큐 남은 {left}")
    if dead: print(f"  dead-letter 는 Redis 의 {DEAD} 에 보관됨")

if __name__ == "__main__":
    main()
