import os, json, time, psycopg2, redis
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="ESP32 OTA API Server")
CLUSTER_NAME = os.getenv("CLUSTER_NAME", "unknown")

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

class ReportPayload(BaseModel):
    device_id: str
    target_version: str
    status: str
    duration_ms: int = 1200
    rssi: int = -55

@app.get("/health")
def health_check():
    try:
        r = get_redis()
        r.ping()
        conn = get_db()
        conn.close()
        return {"status": "UP", "cluster": CLUSTER_NAME, "db": "CONNECTED", "redis": "CONNECTED"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=str(e))

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
        # DR Standby Read-Only 상태이거나 Master DB 장애 시 로컬 Redis AOF 큐에 무손실 적재
        r = get_redis()
        event = payload.dict()
        event["handled_by_cluster"] = CLUSTER_NAME
        event["queued_at"] = int(time.time())
        event["fallback_reason"] = str(db_err).strip()
        r.rpush("ota:dr:report_queue", json.dumps(event))
        return {"result": "QUEUED_IN_REDIS_AOF", "handled_by_cluster": CLUSTER_NAME}
