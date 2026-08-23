#!/bin/sh
# Load the pre-built bitbetter images into a real Docker host.
# Run this on a machine where Docker works (has CAP_SYS_ADMIN).
set -e
DIR=$(dirname "$0")
cd "$DIR"

echo "Loading bitbetter/api..."
docker load -i bitbetter-api-2026.8.0.tar

echo "Loading bitbetter/identity..."
docker load -i bitbetter-identity-2026.8.0.tar

echo ""
echo "Done. Verify with:"
echo "  docker images | grep bitbetter"
echo ""
echo "Then add this to /path/to/bwdata/docker/docker-compose.override.yml:"
echo ""
cat <<'YAML'
services:
  api:
    image: bitbetter/api:2026.8.0
    pull_policy: never
  identity:
    image: bitbetter/identity:2026.8.0
    pull_policy: never
YAML
echo ""
echo "And comment out 'dockerComposePull' in /path/to/bwdata/scripts/run.sh"
