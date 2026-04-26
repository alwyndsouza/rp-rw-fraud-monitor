#!/usr/bin/env bash
set -euo pipefail

NETWORK="rp-rw-fraud-monitor_fraud-net"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Network $NETWORK not found. Start the stack first with 'make up'."
  exit 1
fi

docker run --rm -i \
  --network "$NETWORK" \
  -v "$REPO_ROOT/sql/99_data_quality_checks.sql:/checks.sql:ro" \
  postgres:15.8-alpine \
  psql -h risingwave -p 4566 -U root -d dev -f /checks.sql
