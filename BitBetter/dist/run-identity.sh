#!/bin/bash
# Run the patched Bitwarden Identity service directly (no Docker needed).
# Works in restricted sandboxes where Docker can't run containers.
#
# Usage: ./run-identity.sh [port]
set -e

PORT="${1:-5001}"
DOTNET="/opt/dotnet10/dotnet"
IDENTITY_APP="/tmp/fs-identity/app/Identity.dll"
WORKDIR="/root/.openclaw/workspace"   # must contain appsettings.json

if [ ! -f "$IDENTITY_APP" ]; then
    echo "ERROR: $IDENTITY_APP not found. Run rebuild-in-sandbox.sh first."
    exit 1
fi
if [ ! -f "$WORKDIR/appsettings.json" ]; then
    echo "ERROR: $WORKDIR/appsettings.json not found."
    exit 1
fi

echo "Starting Bitwarden Identity (patched) on port $PORT"
echo "  app:  $IDENTITY_APP"
echo "  cwd:  $WORKDIR"
cd "$WORKDIR"
exec "$DOTNET" "$IDENTITY_APP" --urls "http://0.0.0.0:$PORT"
