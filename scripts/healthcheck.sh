#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f .env ]]; then
  echo "ERROR: .env is missing. Copy .env.example to .env and fill the placeholders." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: missing required command: $1" >&2
    exit 1
  fi
}

need docker
need curl

echo "Checking Docker Compose services..."
docker compose ps

echo
echo "Checking TimescaleDB readiness..."
docker compose exec -T timescaledb pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"

echo
echo "Checking TimescaleDB extension and demo rows..."
docker compose exec -T timescaledb psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'timescaledb';" \
  -c "SELECT COUNT(*) AS demo_measurements, MIN(ts) AS first_ts, MAX(ts) AS last_ts FROM measurements;"

echo
echo "Checking Grafana health..."
curl --fail --silent --show-error "http://${BIND_IP}:3000/api/health"
echo

echo
echo "Health check complete."
