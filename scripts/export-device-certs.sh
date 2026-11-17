#!/bin/bash
# terraform output 에서 디바이스 인증서/키를 꺼내 device-sim/certs/ 에 저장한다.
# 사용: cd terraform && ../scripts/export-device-certs.sh   (또는 저장소 루트에서 실행)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${ROOT}/device-sim/certs"
mkdir -p "${OUT}"
chmod 700 "${OUT}"
cd "${ROOT}/terraform"
terraform output -raw device_certificate_pem > "${OUT}/device.pem.crt"
terraform output -raw device_private_key     > "${OUT}/device.private.key"
terraform output -raw iot_thing_name         > "${OUT}/thing_name.txt"
terraform output -raw iot_endpoint           > "${OUT}/endpoint.txt"
curl -fsS https://www.amazontrust.com/repository/AmazonRootCA1.pem -o "${OUT}/AmazonRootCA1.pem"
chmod 600 "${OUT}"/*
echo "[OK] ${OUT}"
ls -l "${OUT}"
