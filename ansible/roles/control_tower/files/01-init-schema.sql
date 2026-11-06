CREATE TABLE IF NOT EXISTS firmware_releases (
    id SERIAL PRIMARY KEY,
    version VARCHAR(32) UNIQUE NOT NULL,
    s3_url TEXT NOT NULL,
    sha256_hash CHAR(64) NOT NULL,
    file_size_bytes BIGINT NOT NULL,
    release_notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS devices (
    device_id VARCHAR(64) PRIMARY KEY,
    device_group VARCHAR(64) DEFAULT 'default',
    current_version VARCHAR(32),
    last_known_ip VARCHAR(45),
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS ota_deployment_history (
    deployment_id SERIAL PRIMARY KEY,
    device_id VARCHAR(64) REFERENCES devices(device_id),
    target_version VARCHAR(32) NOT NULL,
    status VARCHAR(20) NOT NULL CHECK (status IN ('SUCCESS', 'FAILED', 'ROLLED_BACK')),
    error_code VARCHAR(50),
    duration_ms INTEGER,
    handled_by_cluster VARCHAR(20),
    completed_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS device_telemetry_logs (
    log_id BIGSERIAL PRIMARY KEY,
    device_id VARCHAR(64) REFERENCES devices(device_id),
    firmware_version VARCHAR(32),
    rssi INTEGER,
    free_heap_bytes INTEGER,
    battery_mv INTEGER,
    extra_payload JSONB,
    recorded_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_ota_history_device ON ota_deployment_history(device_id);
CREATE INDEX IF NOT EXISTS idx_telemetry_recorded_at ON device_telemetry_logs(recorded_at);
