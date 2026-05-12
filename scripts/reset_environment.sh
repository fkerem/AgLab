#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ "${1:-}" != "--yes" ]]; then
  echo "This deletes Docker volumes for PostgreSQL, Grafana, and Caddy." >&2
  echo "Run: scripts/reset_environment.sh --yes" >&2
  exit 1
fi

docker compose down -v
echo "Environment volumes removed. Start again with: docker compose up -d"
