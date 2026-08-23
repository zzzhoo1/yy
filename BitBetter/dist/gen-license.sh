#!/bin/bash
# gen-license.sh — Generate a BitBetter self-signed license WITHOUT Docker.
#
# Uses the patched Core.dll (from the extracted Identity/API app dir) and the
# self-signed cert.pfx to produce a Bitwarden license JSON that the patched
# services will accept.
#
# USAGE:
#   ./gen-license.sh user <Name> <Email> <UserGuid> [StorageGB] [Key]
#   ./gen-license.sh org  <Name> <Email> <InstallId> [StorageGB] [BusinessName] [Key]
#
# Examples:
#   ./gen-license.sh user "Test User" "test@example.com" acd79ad4-9919-438b-a889-b4af00c6af05
#   ./gen-license.sh org  "Test Org"   "org@example.com"  11111111-2222-3333-4444-555555555555
#
# Output is printed to stdout as JSON. Redirect to a file to save:
#   ./gen-license.sh user ... > user-license.json

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTNET="${DOTNET:-/opt/dotnet10/dotnet}"
CERT="${CERT:-$DIR/../.keys/cert.pfx}"
# Core.dll can come from either the API or Identity extracted app dir.
CORE="${CORE:-/tmp/fs-api/app/Core.dll}"

LG="$DIR/../src/licenseGen/bin/Release/net10.0/licenseGen.dll"

if [ ! -f "$DOTNET" ]; then
  echo "ERROR: dotnet not found at $DOTNET. Set DOTNET to your .NET 10 SDK path." >&2
  exit 1
fi
if [ ! -f "$CERT" ]; then
  echo "ERROR: cert not found at $CERT. Generate keys first via .keys/generate-keys.sh" >&2
  exit 1
fi
if [ ! -f "$CORE" ]; then
  echo "ERROR: Core.dll not found at $CORE. Set CORE to the patched Core.dll path." >&2
  exit 1
fi
if [ ! -f "$LG" ]; then
  echo "Building licenseGen..." >&2
  ( cd "$DIR/../src/licenseGen" && "$DOTNET" build -c Release >/dev/null )
fi

if [ "$#" -lt 1 ]; then
  echo "USAGE: $0 <user|org> <Name> <Email> <Guid> [StorageGB] [Key]" >&2
  exit 1
fi

exec "$DOTNET" "$LG" --cert "$CERT" --core "$CORE" "$@"
