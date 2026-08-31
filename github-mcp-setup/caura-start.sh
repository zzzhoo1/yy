#!/bin/bash
# Caura local start script
set -e
cd "$(dirname "$0")"
export PATH="$HOME/.local/bin:$PATH"
export PYTHONPATH="$PWD/common:$PWD/core-storage-api/src:$PWD/core-api/src"
export CORE_STORAGE_SHARED_SECRET=local-dev-shared-secret-123

echo "Starting core-storage-api on :8002"
nohup ./venv/bin/python -m uvicorn core_storage_api.app:app --host 0.0.0.0 --port 8002 > /tmp/caura-storage.log 2>&1 &
echo "storage pid: $!"
sleep 5
echo "Starting core-api on :8000"
nohup ./venv/bin/python -m uvicorn core_api.app:app --host 0.0.0.0 --port 8000 > /tmp/caura-api.log 2>&1 &
echo "api pid: $!"
sleep 8
echo "=== health ==="
curl -s http://localhost:8000/api/v1/health; echo
