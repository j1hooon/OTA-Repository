#!/usr/bin/env python3
"""가상 ESP32 OTA 클라이언트.

push : AWS IoT Core(MQTT, mTLS)에서 ota/notify/all 및 ota/notify/<thing> 구독
pull : 시작 시 /ota/check 로 놓친 업데이트 확인 (오프라인 중 발행 메시지 보완)
검증 : CloudFront 에서 펌웨어 다운로드 -> 크기/SHA-256 검증
보고 : POST /ota/report (+ MQTT ota/status/<thing>)

표준 라이브러리 + paho-mqtt(>=2.0) 만 사용한다.
"""
import argparse
import hashlib
import json
import os
import sys
import threading
import time
import urllib.request

STATE_FILE = "device_state.json"


_CTX = {"id": "-", "state": None}


def log(msg):
    ver = load_version(_CTX["state"]) if _CTX["state"] else "?"
    print(f"[{time.strftime('%H:%M:%S')}][{_CTX['id']}|v{ver}] {msg}", flush=True)


def load_version(path):
    try:
        with open(path) as f:
            return json.load(f)["version"]
    except Exception:
        return "0.0.0"


def save_version(path, version):
    with open(path, "w") as f:
        json.dump({"version": version}, f)


def http_post_json(url, body, timeout=10):
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), method="POST",
        headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.status, r.read().decode()


def download_and_verify(url, sha256, size, retries=5, delay=3):
    """다운로드 후 (ok, reason) 반환. CDN 전파 지연을 고려해 재시도."""
    last = "unknown"
    for attempt in range(1, retries + 1):
        try:
            h, n = hashlib.sha256(), 0
            with urllib.request.urlopen(url, timeout=30) as r:
                while True:
                    chunk = r.read(65536)
                    if not chunk:
                        break
                    h.update(chunk)
                    n += len(chunk)
            if size and n != int(size):
                last = f"SIZE_MISMATCH(expected={size}, got={n})"
            elif h.hexdigest() != sha256:
                last = "HASH_MISMATCH"
            else:
                return True, "OK"
        except Exception as e:  # noqa: BLE001
            last = f"DOWNLOAD_ERROR({e})"
        log(f"⚠️ 다운로드/검증 실패({last}), 재시도 {attempt}/{retries}")
        time.sleep(delay)
    return False, last


def process_update(fw, device_id, api, state_path, publish_status=None):
    """펌웨어 업데이트 1건 처리. 성공 시 True."""
    version = fw["version"]
    current = load_version(state_path)
    if version == current:
        log(f"이미 최신 펌웨어(v{current})가 적용되어 있습니다. 업데이트를 건너뜁니다.")
        return False
    log(f"�� 신규 OTA 업데이트 시작: v{current} -> v{version}")
    log(f"   다운로드 URL (CloudFront): {fw['url']}")
    t0 = time.time()
    ok, reason = download_and_verify(fw["url"], fw["sha256"], fw.get("size"))
    ms = int((time.time() - t0) * 1000)
    status = "SUCCESS" if ok else f"FAILED_{reason.split('(')[0]}"
    if ok:
        time.sleep(0.3)  # 플래시 기록 시뮬레이션 (실제 기기라면 여기서 flash + reboot)
        save_version(state_path, version)
        log(f"✅ SHA-256/크기 검증 통과, 펌웨어 적용 완료! 현재 버전: v{version} ({ms} ms)")
    else:
        log(f"❌ OTA 업데이트 실패: {reason}")
    report = {"device_id": device_id, "target_version": version,
              "status": status, "duration_ms": ms, "rssi": -55}
    try:
        code, body = http_post_json(f"{api}/ota/report", report)
        log(f"�� HTTP /ota/report 보고 완료 ({code}): {body}")
    except Exception as e:  # noqa: BLE001
        log(f"⚠️ HTTP /ota/report 전송 실패: {e}")
    if publish_status:
        publish_status(json.dumps(report))
        log(f"�� MQTT 상태 보고 발행 완료 -> Topic: ota/status/{device_id}")
    return ok


def pull_check(device_id, api, state_path, publish_status=None):
    cur = load_version(state_path)
    url = f"{api}/ota/check?device_id={device_id}&current_version={cur}"
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            data = json.loads(r.read().decode())
    except Exception as e:  # noqa: BLE001
        log(f"⚠️ /ota/check 실패(건너뜀): {e}")
        return False
    fw = data.get("latest_firmware")
    if data.get("update_required") and fw:
        log(f"�� /ota/check(pull): 새 버전 v{fw['version']} 발견 (Source={data.get('data_source')}, Cluster={data.get('handled_by_cluster')})")
        return process_update(fw, device_id, api, state_path, publish_status)
    log(f"/ota/check 완료: 최신 상태 (Source={data.get('data_source')}, Cluster={data.get('handled_by_cluster')})")
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--certs", default=os.path.join(os.path.dirname(__file__), "certs"))
    ap.add_argument("--api", default=os.getenv("API_BASE_URL", "http://172.16.10.1:8000"))
    ap.add_argument("--state", default=os.path.join(os.path.dirname(__file__), STATE_FILE))
    ap.add_argument("--once", action="store_true", help="업데이트 1건 처리 후 종료")
    ap.add_argument("--no-pull", action="store_true", help="시작 시 /ota/check 생략")
    args = ap.parse_args()

    import ssl
    import paho.mqtt.client as mqtt

    rd = lambda n: open(os.path.join(args.certs, n)).read().strip()  # noqa: E731
    thing, endpoint = rd("thing_name.txt"), rd("endpoint.txt")

    _CTX["id"], _CTX["state"] = thing, args.state
    log(f"부팅 완료. 브로커 접속 시도 중... ({endpoint}:8883)")
    done = threading.Event()
    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=thing)  # client_id == Thing 이름 (정책 조건)
    c.tls_set(ca_certs=os.path.join(args.certs, "AmazonRootCA1.pem"),
              certfile=os.path.join(args.certs, "device.pem.crt"),
              keyfile=os.path.join(args.certs, "device.private.key"),
              tls_version=ssl.PROTOCOL_TLSv1_2)
    pub = lambda payload: c.publish(f"ota/status/{thing}", payload, qos=1)  # noqa: E731

    def on_connect(cl, ud, flags, rc, props=None):
        if rc != 0:
            log(f"❌ MQTT 연결 실패 (rc={rc})")
            return
        log(f"�� AWS IoT Core mTLS(8883) 연결 성공! (Endpoint: {endpoint})")
        for t in ("ota/notify/all", f"ota/notify/{thing}"):
            cl.subscribe(t, qos=1)

    def on_subscribe(cl, ud, mid, rcs, props=None):
        log(f"�� MQTT 구독 결과: {[str(x) for x in rcs]}  (Not authorized 면 정책/Client ID 확인)")

    def on_message(cl, ud, msg):
        log(f"�� [MQTT Push 수신] Topic={msg.topic} | Payload={msg.payload.decode(errors='replace')}")
        try:
            m = json.loads(msg.payload)
        except ValueError:
            return
        if m.get("command") != "OTA_UPDATE":
            return
        fw = {k: m.get(k) for k in ("version", "url", "sha256", "size")}
        process_update(fw, thing, args.api, args.state, pub)
        if args.once:
            done.set()

    def on_disconnect(cl, ud, flags, rc, props=None):
        log(f"�� MQTT 연결 끊김 (rc={rc}) - 자동 재연결 대기")

    c.on_connect, c.on_subscribe, c.on_message = on_connect, on_subscribe, on_message
    c.on_disconnect = on_disconnect
    c.connect(endpoint, 8883, keepalive=30)
    c.loop_start()
    if not args.no_pull:
        if pull_check(thing, args.api, args.state, pub) and args.once:
            done.set()
    try:
        if args.once:
            done.wait()
        else:
            while True:
                time.sleep(3600)
    except KeyboardInterrupt:
        pass
    c.loop_stop()
    c.disconnect()


if __name__ == "__main__":
    sys.exit(main())
