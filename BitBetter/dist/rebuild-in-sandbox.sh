#!/bin/sh
# Rebuild bitbetter images WITHOUT Docker (works in restricted sandboxes).
# Requires: crane, dotnet (8+), openssl, jq
set -e
export PATH=$PATH:/opt/dotnet:/usr/local/bin
REPO=$(cd "$(dirname "$0")/.." && pwd)
VERSION=$(curl -fsSL https://raw.githubusercontent.com/bitwarden/self-host/refs/heads/main/version.json | jq -r '.versions.coreVersion')
echo "Bitwarden version: $VERSION"

# 1. Generate keys if missing
[ -e "$REPO/.keys/cert.cert" ] || "$REPO/.keys/generate-keys.sh"

# 2. Build patcher (net8 compatible)
cd "$REPO/src/bitBetter"
sed -i 's#<TargetFramework>net10.0</TargetFramework>#<TargetFramework>net8.0</TargetFramework>#' bitBetter.csproj
sed -i 's#X509CertificateLoader.LoadCertificate#new X509Certificate2#' Program.cs
dotnet publish -c Release -o bin/Release/net8.0/publish

# 3. Pull, extract, patch, repack for api and identity
for svc in api identity; do
  echo "=== Processing $svc ==="
  crane pull "ghcr.io/bitwarden/$svc:$VERSION" /tmp/bw-$svc.tar
  mkdir -p /tmp/fs-$svc && cd /tmp/fs-$svc
  tar -xf /tmp/bw-$svc.tar
  for f in *.tar.gz; do tar -xzf "$f" 2>/dev/null; done
  # Patch the single-file executable
  dotnet "$REPO/src/bitBetter/bin/Release/net8.0/publish/bitBetter.dll" \
    "$REPO/.keys/cert.cert" "/tmp/fs-$svc/app/$svc"
  # Replace executable with wrapper script
  EXEC=$(echo "$svc" | sed 's/^\(.\)/\U\1/')  # Api / Identity
  rm -f "/tmp/fs-$svc/app/$EXEC"
  printf '#!/bin/sh\nexec dotnet /app/%s.dll "$@"\n' "$EXEC" > "/tmp/fs-$svc/app/$EXEC"
  chmod +x "/tmp/fs-$svc/app/$EXEC"
  # Repack app dir as new layer and append
  tar --sort=name --mtime='2026-01-01' --owner=0 --group=0 --numeric-owner \
    -czf /tmp/$svc-layer.tar.gz app
  crane append -b "ghcr.io/bitwarden/$svc:$VERSION" -f /tmp/$svc-layer.tar.gz \
    -t "bitbetter/$svc:$VERSION" -o "dist/bitbetter-$svc-$VERSION.tar"
done
echo "Done. Images in dist/"
