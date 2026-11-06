#!/bin/bash
set -e
cd ~/ota-platform/terraform
HB_KEY_ID=$(terraform output -raw heartbeat_iam_access_key_id)
HB_SECRET_KEY=$(terraform output -raw heartbeat_iam_secret_access_key)

sudo bash -c "cat << EOT > /etc/default/ota-heartbeat
AWS_ACCESS_KEY_ID=${HB_KEY_ID}
AWS_SECRET_ACCESS_KEY=${HB_SECRET_KEY}
AWS_DEFAULT_REGION=ap-northeast-1
EOT"
sudo chmod 600 /etc/default/ota-heartbeat
sudo systemctl daemon-reload
sudo systemctl enable ota-heartbeat.service
sudo systemctl restart ota-heartbeat.service
sudo systemctl status ota-heartbeat.service --no-pager
