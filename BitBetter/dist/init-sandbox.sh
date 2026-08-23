#!/bin/bash
# One-shot: initialize the SQLite DB + test user for the patched Bitwarden
# services, then start Identity and API. No Docker required.
#
# Prereqs (see README):
#   - BitBetter/dist/bitbetter-{api,identity}-<ver>.tar built via rebuild-in-sandbox.sh
#   - extracted app dirs at /tmp/fs-api/app and /tmp/fs-identity/app
#   - /opt/dotnet10/dotnet (or set DOTNET) .NET 10 runtime
#   - workspace appsettings.json + appsettings.SelfHosted.json
#
# Usage: ./init-sandbox.sh
set -e

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DOTNET="${DOTNET:-/opt/dotnet10/dotnet}"
IDENTITY_APP="/tmp/fs-identity/app/Identity.dll"
API_APP="/tmp/fs-api/app/Api.dll"
WORKDIR="${WORKDIR:-/root/.openclaw/workspace}"
DATA_DIR="${BW_DATA_DIR:-/tmp/bw-data}"

echo "=== BitBetter sandbox init ==="
echo "  data dir: $DATA_DIR"

# 0. Make sure app dirs are extracted
if [ ! -f "$IDENTITY_APP" ]; then
    echo "ERROR: $IDENTITY_APP not found. Run rebuild-in-sandbox.sh / extract images first."
    exit 1
fi

# 1. Build + run initdb to create schema + test user
echo ""
echo "=== [1/4] Building initdb tool ==="
cd "$REPO/dist/initdb"
"$DOTNET" build -c Release --no-incremental >/dev/null
echo "  built."

echo "=== [2/4] Initializing DB (schema + test user) ==="
# initdb.dll must be next to the app DLLs so OnResolve can find them
cp bin/Release/net10.0/initdb.dll /tmp/fs-identity/app/initdb.dll
cd /tmp/fs-identity/app
BW_APP_DIR=/tmp/fs-identity/app BW_DATA_DIR="$DATA_DIR" \
  "$DOTNET" initdb.dll 2>&1 | sed 's/^/  [initdb] /'
echo "  DB ready at $DATA_DIR/bw.db"

# 2. Start services
echo "=== [3/4] Starting Identity on :5001 ==="
export globalSettings__selfHosted=true
cd "$WORKDIR"
nohup "$DOTNET" "$IDENTITY_APP" --urls "http://0.0.0.0:5001" > /tmp/api-identity.log 2>&1 &
IDENTITY_PID=$!
echo "  Identity pid $IDENTITY_PID (log: /tmp/api-identity.log)"

echo "=== [4/4] Starting API on :5000 ==="
nohup "$DOTNET" "$API_APP" --urls "http://0.0.0.0:5000" > /tmp/api-api.log 2>&1 &
API_PID=$!
echo "  API pid $API_PID (log: /tmp/api-api.log)"

echo ""
echo "=== Done. Services starting. ==="
echo "  Identity: http://127.0.0.1:5001"
echo "  API:      http://127.0.0.1:5000"
echo "  Test user: test@example.com / password123"
echo ""
echo "Wait a few seconds, then verify:"
echo "  curl -s http://127.0.0.1:5001/.well-known/openid-configuration"
echo "  curl -s http://127.0.0.1:5000/alive"
