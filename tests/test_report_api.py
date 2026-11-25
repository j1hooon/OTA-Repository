"""ota_api/files/main.py 의 /ota/report 입력 검증과 DR 큐 상한 시험.

FastAPI·psycopg2 없이 돌도록, main.py 에서 ReportPayload 와 enqueue_report 등만 AST 로 추출해
그대로 실행한다(코드를 복사하지 않으므로 main.py 와 어긋나지 않는다).
큐 상한은 실제 redis-server 를 임시 포트로 띄워 Lua 스크립트까지 시험한다.

  python -m unittest discover -s tests -v      # pydantic 과 redis-server/redis-cli 필요
"""
import ast, json, os, shutil, subprocess, time, unittest
from pathlib import Path
from typing import Optional
from pydantic import BaseModel, Field, ValidationError, model_validator

SRC = Path(__file__).resolve().parents[1] / "ansible/roles/ota_api/files/main.py"
WANT = {"DEVICE_ID_PATTERN", "VERSION_PATTERN", "STATUS_PATTERN", "DR_QUEUE_KEY", "DR_QUEUE_MAX", "_ENQUEUE_LUA"}


def load_ns():
    tree = ast.parse(SRC.read_text(encoding="utf-8"))
    nodes = [n for n in tree.body
             if (isinstance(n, ast.Assign) and any(getattr(t, "id", None) in WANT for t in n.targets))
             or (isinstance(n, ast.ClassDef) and n.name == "ReportPayload")
             or (isinstance(n, ast.FunctionDef) and n.name == "enqueue_report")]
    assert len(nodes) == len(WANT) + 2, f"main.py 에서 시험 대상 {len(WANT) + 2}개를 찾지 못함: {len(nodes)}"
    ns = {"os": os, "json": json, "Optional": Optional, "BaseModel": BaseModel, "Field": Field,
          "model_validator": model_validator}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(SRC), "exec"), ns)
    return ns


NS = load_ns()
RP = NS["ReportPayload"]


def ok(**kw):
    base = dict(device_id="d1", target_version="1.0.0", status="SUCCESS")
    return RP(**{**base, **kw})


class PayloadValidation(unittest.TestCase):
    def test_success_unchanged(self):
        p = ok(device_id="esp32-ci-verifier", target_version="1.0.1")
        self.assertEqual((p.status, p.error_code), ("SUCCESS", None))

    def test_failed_reason_is_normalized_to_schema(self):
        # 기기 시뮬레이터가 보내는 형식 -> DB CHECK(status IN SUCCESS/FAILED/ROLLED_BACK) 를 만족해야 한다
        for sent, code in [("FAILED_HASH_MISMATCH", "HASH_MISMATCH"), ("FAILED_DOWNLOAD_ERROR", "DOWNLOAD_ERROR"),
                           ("FAILED_SIZE_MISMATCH", "SIZE_MISMATCH")]:
            p = ok(status=sent)
            self.assertEqual((p.status, p.error_code), ("FAILED", code), sent)

    def test_plain_failed_and_rolled_back(self):
        self.assertEqual(ok(status="FAILED").status, "FAILED")
        self.assertEqual(ok(status="ROLLED_BACK").status, "ROLLED_BACK")

    def test_e2e_probe_body_is_accepted(self):  # scripts/measure-dr-e2e.sh 가 보내는 본문
        p = ok(device_id="e2e-probe", target_version="e2e", duration_ms=1, rssi=-50)
        self.assertEqual(p.status, "SUCCESS")

    def test_rejected_inputs(self):
        bad = {
            "device_id 65자": dict(device_id="x" * 65),
            "device_id 빈 문자열": dict(device_id=""),
            "device_id 특수문자": dict(device_id="a b;drop"),
            "target_version 33자": dict(target_version="1" * 33),
            "status 임의 문자열": dict(status="PWNED"),
            "status 소문자": dict(status="success"),
            "FAILED 사유 41자": dict(status="FAILED_" + "A" * 41),
            "duration_ms 음수": dict(duration_ms=-1),
            "duration_ms 1일": dict(duration_ms=86_400_000),
            "rssi 양수": dict(rssi=10),
        }
        for name, kw in bad.items():
            with self.subTest(name):
                with self.assertRaises(ValidationError):
                    ok(**kw)


@unittest.skipUnless(shutil.which("redis-server") and shutil.which("redis-cli"), "redis-server/redis-cli 필요")
class QueueCap(unittest.TestCase):
    PORT = "56379"
    KEY = NS["DR_QUEUE_KEY"]

    @classmethod
    def setUpClass(cls):
        cls.proc = subprocess.Popen(["redis-server", "--port", cls.PORT, "--save", "", "--appendonly", "no"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if cls.cli("ping") == "PONG":
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("redis-server 가 뜨지 않음")

    @classmethod
    def tearDownClass(cls):
        cls.proc.terminate()
        cls.proc.wait(timeout=5)

    @classmethod
    def cli(cls, *a):
        return subprocess.run(["redis-cli", "-p", cls.PORT, *a], capture_output=True, text=True).stdout.strip()

    def setUp(self):
        self.cli("del", self.KEY)
        outer = self

        class R:  # redis-py 의 eval(script, numkeys, *args) 와 같은 모양의 어댑터
            def eval(self, script, numkeys, *args):
                return int(outer.cli("eval", script, str(numkeys), *map(str, args)))
        self.r = R()

    def test_cap_rejects_with_minus_one_and_keeps_queue(self):
        enq = NS["enqueue_report"]
        self.assertEqual([enq(self.r, {"i": i}, max_len=3) for i in range(5)], [1, 2, 3, -1, -1])
        self.assertEqual(self.cli("llen", self.KEY), "3")
        self.assertEqual(self.cli("lrange", self.KEY, "0", "-1").split("\n"), ['{"i": 0}', '{"i": 1}', '{"i": 2}'])

    def test_accepts_again_after_drain(self):
        enq = NS["enqueue_report"]
        for i in range(3):
            enq(self.r, {"i": i}, max_len=3)
        self.cli("ltrim", self.KEY, "3", "-1")  # drain-dr-queue.py 의 LTRIM
        self.assertEqual(enq(self.r, {"i": 9}, max_len=3), 1)

    def test_default_cap(self):
        self.assertEqual(NS["DR_QUEUE_MAX"], 10000)


if __name__ == "__main__":
    unittest.main()
