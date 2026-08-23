#!/bin/bash
# Run the patched Bitwarden API service directly (no Docker needed).
# Works in restricted sandboxes where Docker can't run containers.
#
# Usage: ./run-api.sh [port]
set -e

PORT="${1:-5000}"
DOTNET="/opt/dotnet10/dotnet"
API_APP="/tmp/fs-api/app/Api.dll"
WORKDIR="/root/.openclaw/workspace"   # must contain appsettings.json

if [ ! -f "$API_APP" ]; then
    echo "ERROR: $API_APP not found. Run rebuild-in-sandbox.sh first."
    exit 1
fi

echo "Starting Bitwarden API (patched) on port $PORT"
echo "  app:  $API_APP"
echo "  cwd:  $WORKDIR"
cd "$WORKDIR"
exec "$DOTNET" "$API_APP" --urls "http://0.0.0.0:$PORT"
