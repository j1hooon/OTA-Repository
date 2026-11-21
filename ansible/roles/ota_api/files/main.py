import os, json, time, hmac, uuid, psycopg2, redis, boto3
import threading, logging
from datetime import datetime, timezone
from botocore.config import Config
from fastapi import FastAPI, HTTPException, Depends, Header
from pydantic import BaseModel

app = FastAPI(title="ESP32 OTA API Server (AWS IoT Core Hybrid)")
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown")
AWS_REGION = os.getenv("AWS_DEFAULT_REGION", "ap-northeast-1")
IOT_ENDPOINT = os.getenv("IOT_ENDPOINT", "")
PUBLISH_API_KEY = os.getenv("PUBLISH_API_KEY", "")

def get_db():
    return psycopg2.connect(
        host=os.getenv("PG_HOST"),
        database=os.getenv("PG_DB"),
        user=os.getenv("PG_USER"),
        password=os.getenv("PG_PASS"),
        connect_timeout=3
    )

def get_redis():
    return redis.Redis(
        host=os.getenv("REDIS_HOST"),
        port=6379,
        password=os.getenv("REDIS_PASS"),
        decode_responses=True,
        socket_timeout=2
    )

def get_iot_client():
    # 외부 통신 장애(DNS 등) 시 요청이 수십 초 매달리지 않고 빠르게 실패(502)하도록 타임아웃 지정
    kwargs = {"region_name": AWS_REGION,
              "config": Config(connect_timeout=3, read_timeout=5, retries={"max_attempts": 1})}
    if IOT_ENDPOINT:
        kwargs["endpoint_url"] = f"https://{IOT_ENDPOINT}" if not IOT_ENDPOINT.startswith("http") else IOT_ENDPOINT
    return boto3.client("iot-data", **kwargs)


def require_publish_key(x_api_key: str = Header(default="")):
    """/ota/publish 전용 API 키 검증 (X-API-Key 헤더). 키가 설정되지 않았으면 fail-closed."""
    if not PUBLISH_API_KEY:
        raise HTTPException(status_code=503, detail="Publish is disabled: PUBLISH_API_KEY is not configured")
    if not hmac.compare_digest(x_api_key.encode("utf-8"), PUBLISH_API_KEY.encode("utf-8")):
        raise HTTPException(status_code=401, detail="Invalid or missing API key")

class PublishPayload(BaseModel):
    version: str
    url: str
    sha256: str
    file_size_bytes: int = 524288
    release_notes: str = "Automated OTA Release"
    target_device: str = "all"

class ReportPayload(BaseModel):
    device_id: str
    target_version: str
    status: str
    duration_ms: int = 1200
    rssi: int = -55

# ---------------------------------------------------------------------------
# 기기 상태 수집: IoT Rule -> SQS -> (이 소비자) -> PostgreSQL
#  - 복제본 N개가 같은 큐를 경쟁 소비. SQS 는 at-least-once 이므로 쓰기는 멱등(MessageId 기준)이다.
#  - DB 장애/절체 중에는 삭제하지 않고 큐에 남겨 두어 유실을 막는다(보관 4일, 5회 실패 시 DLQ).
#  - STATUS_QUEUE_URL 이 비어 있으면 소비자는 꺼진다(fail-soft).
# ---------------------------------------------------------------------------
STATUS_QUEUE_URL = os.getenv("STATUS_QUEUE_URL", "")
_log = logging.getLogger("uvicorn.error")

STATUS_DDL = """
CREATE TABLE IF NOT EXISTS device_status_history (
    message_id  TEXT PRIMARY KEY,
    device_id   TEXT NOT NULL,
    payload     JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_dsh_device_time ON device_status_history (device_id, received_at DESC);
CREATE TABLE IF NOT EXISTS device_status_latest (
    device_id   TEXT PRIMARY KEY,
    payload     JSONB NOT NULL,
    received_at TIMESTAMPTZ NOT NULL,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
"""

def get_sqs_client():
    # read_timeout 은 롱폴링(WaitTimeSeconds=20)보다 길어야 한다
    return boto3.client("sqs", region_name=AWS_REGION,
                        config=Config(connect_timeout=3, read_timeout=25, retries={"max_attempts": 2}))

def ensure_status_schema():
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute("SELECT pg_advisory_xact_lock(827364)")  # 복제본 동시 시작 시 DDL 직렬화
        cur.execute(STATUS_DDL)
        conn.commit()
        cur.close()
    finally:
        conn.close()

def save_status(conn, message_id, body):
    device_id = body.get("thing")
    if not device_id:
        raise ValueError("message has no 'thing'")
    received_ms = body.get("received_at")
    received_at = datetime.fromtimestamp((received_ms or time.time() * 1000) / 1000.0, tz=timezone.utc)
    payload = json.dumps(body)
    cur = conn.cursor()
    cur.execute("""
        INSERT INTO device_status_history (message_id, device_id, payload, received_at)
        VALUES (%s, %s, %s::jsonb, %s)
        ON CONFLICT (message_id) DO NOTHING;
    """, (message_id, device_id, payload, received_at))
    cur.execute("""
        INSERT INTO device_status_latest (device_id, payload, received_at)
        VALUES (%s, %s::jsonb, %s)
        ON CONFLICT (device_id) DO UPDATE
            SET payload = EXCLUDED.payload, received_at = EXCLUDED.received_at, updated_at = now()
            WHERE device_status_latest.received_at <= EXCLUDED.received_at;
    """, (device_id, payload, received_at))
    cur.close()

def status_consumer_loop():
    sqs = get_sqs_client()
    schema_ready = False
    _log.info("status consumer started: %s", STATUS_QUEUE_URL)
    while True:
        try:
            if not schema_ready:
                ensure_status_schema()
                schema_ready = True
            resp = sqs.receive_message(QueueUrl=STATUS_QUEUE_URL, MaxNumberOfMessages=10, WaitTimeSeconds=20)
            msgs = resp.get("Messages", [])
            if not msgs:
                continue
            conn = get_db()  # DB 가 죽어 있으면 여기서 예외 -> 메시지는 큐에 그대로 남는다
            try:
                for m in msgs:
                    try:
                        save_status(conn, m["MessageId"], json.loads(m["Body"]))
                        conn.commit()
                        sqs.delete_message(QueueUrl=STATUS_QUEUE_URL, ReceiptHandle=m["ReceiptHandle"])
                    except Exception as e:  # 삭제하지 않음 -> 가시성 만료 후 재시도, 5회 실패 시 DLQ
                        conn.rollback()
                        _log.warning("status message %s not processed: %s", m.get("MessageId"), e)
            finally:
                conn.close()
        except Exception as e:
            _log.error("status consumer error: %s", e)
            time.sleep(5)

@app.on_event("startup")
def start_status_consumer():
    if not STATUS_QUEUE_URL:
        _log.info("status consumer disabled (STATUS_QUEUE_URL not set)")
        return
    threading.Thread(target=status_consumer_loop, name="status-consumer", daemon=True).start()

@app.get("/ota/status/{device_id}", dependencies=[Depends(require_publish_key)])
def device_status(device_id: str):
    conn = get_db()
    try:
        cur = conn.cursor()
        cur.execute("SELECT payload, received_at FROM device_status_latest WHERE device_id = %s;", (device_id,))
        row = cur.fetchone()
        cur.close()
    finally:
        conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="No status for this device")
    return {"device_id": device_id, "received_at": row[1].isoformat(), "status": row[0]}

@app.get("/health")
def health_check():
    try:
        r = get_redis()
        r.ping()
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT 1;")
        cur.close()
        conn.close()
        return {"status": "UP", "cluster": CLUSTER_NAME, "db": "CONNECTED", "redis": "CONNECTED"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))

@app.post("/ota/publish", dependencies=[Depends(require_publish_key)])
def publish_firmware(payload: PublishPayload):
    # 1. PostgreSQL에 신규 펌웨어 메타데이터 Upsert
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO firmware_releases (version, s3_url, sha256_hash, file_size_bytes, release_notes)
            VALUES (%s, %s, %s, %s, %s)
            ON CONFLICT (version) DO UPDATE SET
                s3_url = EXCLUDED.s3_url,
                sha256_hash = EXCLUDED.sha256_hash,
                file_size_bytes = EXCLUDED.file_size_bytes,
                release_notes = EXCLUDED.release_notes,
                created_at = CURRENT_TIMESTAMP;
        """, (payload.version, payload.url, payload.sha256, payload.file_size_bytes, payload.release_notes))
        conn.commit()
        cur.close()
        conn.close()
    except Exception as db_err:
        raise HTTPException(status_code=500, detail=f"DB Update Failed: {str(db_err)}")

    # 2. Redis 캐시 즉시 갱신 (Write-Through)
    fw_data = {
        "version": payload.version,
        "url": payload.url,
        "sha256": payload.sha256,
        "size": payload.file_size_bytes
    }
    r = get_redis()
    r.setex("latest_firmware", 300, json.dumps(fw_data))

    # 3. AWS IoT Core (MQTT Control Plane)로 실시간 Push 알림 발행
    topic = f"ota/notify/{payload.target_device}"
    mqtt_message = {
        "command": "OTA_UPDATE",
        "version": payload.version,
        "url": payload.url,
        "sha256": payload.sha256,
        "size": payload.file_size_bytes,
        "published_by": CLUSTER_NAME,
        "timestamp": int(time.time())
    }
    try:
        iot = get_iot_client()
        iot.publish(
            topic=topic,
            qos=1,
            payload=json.dumps(mqtt_message)
        )
        mqtt_status = "PUBLISHED_TO_AWS_IOT_CORE"
    except Exception as iot_err:
        raise HTTPException(status_code=502, detail=f"DB/Redis updated, but AWS IoT Publish failed: {str(iot_err)}")

    return {
        "result": "SUCCESS",
        "handled_by_cluster": CLUSTER_NAME,
        "mqtt_status": mqtt_status,
        "topic": topic,
        "firmware": fw_data
    }

@app.get("/ota/check")
def check_update(device_id: str = "esp32-dev-01", current_version: str = "0.9.0"):
    r = get_redis()
    cached = r.get("latest_firmware")
    source = "REDIS_CACHE"

    if not cached:
        source = "POSTGRES_DB"
        conn = get_db()
        cur = conn.cursor()
        cur.execute("SELECT version, s3_url, sha256_hash, file_size_bytes FROM firmware_releases ORDER BY created_at DESC LIMIT 1;")
        row = cur.fetchone()
        cur.close()
        conn.close()
        if not row:
            raise HTTPException(status_code=404, detail="No firmware found")
        fw_data = {"version": row[0], "url": row[1], "sha256": row[2], "size": row[3]}
        r.setex("latest_firmware", 300, json.dumps(fw_data))
    else:
        fw_data = json.loads(cached)

    return {
        "handled_by_cluster": CLUSTER_NAME,
        "data_source": source,
        "device_id": device_id,
        "update_required": fw_data["version"] != current_version,
        "latest_firmware": fw_data
    }

@app.post("/ota/report")
def report_status(payload: ReportPayload):
    try:
        conn = get_db()
        cur = conn.cursor()
        cur.execute("""
            INSERT INTO devices (device_id, current_version, updated_at)
            VALUES (%s, %s, CURRENT_TIMESTAMP)
            ON CONFLICT (device_id) DO UPDATE SET current_version = EXCLUDED.current_version, updated_at = CURRENT_TIMESTAMP;
        """, (payload.device_id, payload.target_version))
        cur.execute("""
            INSERT INTO ota_deployment_history (device_id, target_version, status, duration_ms, handled_by_cluster)
            VALUES (%s, %s, %s, %s, %s);
        """, (payload.device_id, payload.target_version, payload.status, payload.duration_ms, CLUSTER_NAME))
        conn.commit()
        cur.close()
        conn.close()
        return {"result": "RECORDED_IN_DB", "handled_by_cluster": CLUSTER_NAME}
    except Exception as db_err:
        r = get_redis()
        event = payload.dict()
        event["handled_by_cluster"] = CLUSTER_NAME
        event["queued_at"] = int(time.time())
        event["event_id"] = uuid.uuid4().hex  # 복귀 후 반영 시 중복 방지 키
        event["fallback_reason"] = str(db_err).strip()
        r.rpush("ota:dr:report_queue", json.dumps(event))
        return {"result": "QUEUED_IN_REDIS_AOF", "handled_by_cluster": CLUSTER_NAME}
