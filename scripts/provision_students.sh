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
need jq
need openssl

if ! [[ "${STUDENT_COUNT:-}" =~ ^[0-9]+$ ]] || [[ "$STUDENT_COUNT" -lt 1 ]]; then
  echo "ERROR: STUDENT_COUNT must be a positive integer." >&2
  exit 1
fi

STUDENT_PASSWORD_LENGTH="${STUDENT_PASSWORD_LENGTH:-18}"
if ! [[ "$STUDENT_PASSWORD_LENGTH" =~ ^[0-9]+$ ]] || [[ "$STUDENT_PASSWORD_LENGTH" -lt 12 ]]; then
  echo "ERROR: STUDENT_PASSWORD_LENGTH must be an integer of at least 12." >&2
  exit 1
fi

PREPROVISION_STUDENT_DATASOURCES="${PREPROVISION_STUDENT_DATASOURCES:-false}"
CREDENTIAL_DIR="$ROOT_DIR/credentials"
CREDENTIAL_FILE="$CREDENTIAL_DIR/student_credentials.csv"
mkdir -p "$CREDENTIAL_DIR"
chmod 700 "$CREDENTIAL_DIR"

if [[ ! -f "$CREDENTIAL_FILE" ]]; then
  printf 'username,password,postgres_schema,grafana_org\n' > "$CREDENTIAL_FILE"
  chmod 600 "$CREDENTIAL_FILE"
fi

password_for() {
  local username="$1"
  local existing
  existing="$(awk -F, -v u="$username" 'NR > 1 && $1 == u {print $2; exit}' "$CREDENTIAL_FILE")"
  if [[ -n "$existing" ]]; then
    printf '%s\n' "$existing"
    return
  fi
  local byte_count
  local raw_password
  byte_count=$(( (STUDENT_PASSWORD_LENGTH + 1) / 2 ))
  raw_password="$(openssl rand -hex "$byte_count")"
  printf '%s\n' "${raw_password:0:$STUDENT_PASSWORD_LENGTH}"
}

ensure_csv_row() {
  local username="$1"
  local password="$2"
  local schema="$3"
  local org="$4"
  if ! awk -F, -v u="$username" 'NR > 1 && $1 == u {found = 1} END {exit !found}' "$CREDENTIAL_FILE"; then
    printf '%s,%s,%s,%s\n' "$username" "$password" "$schema" "$org" >> "$CREDENTIAL_FILE"
  fi
}

psql_admin() {
  docker compose exec -T timescaledb psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 "$@"
}

grafana_api() {
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local org_header="${4:-}"
  local url="http://${BIND_IP}:3000${path}"
  local args=(--silent --show-error --fail-with-body -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" -X "$method")
  if [[ -n "$org_header" ]]; then
    args+=(-H "X-Grafana-Org-Id: $org_header")
  fi
  if [[ -n "$body" ]]; then
    args+=(-H "Content-Type: application/json" --data "$body")
  fi
  curl "${args[@]}" "$url"
}

ensure_pg_student() {
  local username="$1"
  local password="$2"
  local schema="$3"

  psql_admin <<SQL >/dev/null
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$username') THEN
    CREATE ROLE "$username" LOGIN PASSWORD '$password';
  ELSE
    ALTER ROLE "$username" WITH LOGIN PASSWORD '$password';
  END IF;
END
\$\$;

CREATE SCHEMA IF NOT EXISTS "$schema" AUTHORIZATION "$username";
ALTER SCHEMA "$schema" OWNER TO "$username";
GRANT CONNECT ON DATABASE "$POSTGRES_DB" TO "$username";
GRANT USAGE ON SCHEMA public TO "$username";
GRANT USAGE, CREATE ON SCHEMA "$schema" TO "$username";
ALTER ROLE "$username" SET search_path = "$schema", public;
SQL
}

ensure_grafana_user() {
  local username="$1"
  local password="$2"
  local user_id

  user_id="$(grafana_api GET "/api/users/lookup?loginOrEmail=${username}" 2>/dev/null | jq -r '.id // empty' || true)"
  if [[ -z "$user_id" ]]; then
    user_id="$(grafana_api POST "/api/admin/users" "$(jq -cn \
      --arg name "$username" \
      --arg email "${username}@example.invalid" \
      --arg login "$username" \
      --arg password "$password" \
      '{name:$name,email:$email,login:$login,password:$password}')" | jq -r '.id')"
  else
    grafana_api PUT "/api/admin/users/${user_id}/password" "$(jq -cn --arg password "$password" '{password:$password}')" >/dev/null
  fi

  printf '%s\n' "$user_id"
}

ensure_grafana_org() {
  local org="$1"
  local org_id

  org_id="$(grafana_api GET "/api/orgs/name/${org}" 2>/dev/null | jq -r '.id // empty' || true)"
  if [[ -z "$org_id" ]]; then
    org_id="$(grafana_api POST "/api/orgs" "$(jq -cn --arg name "$org" '{name:$name}')" | jq -r '.orgId // .id')"
  fi

  printf '%s\n' "$org_id"
}

ensure_org_membership() {
  local org_id="$1"
  local username="$2"

  grafana_api POST "/api/orgs/${org_id}/users" "$(jq -cn --arg loginOrEmail "$username" '{loginOrEmail:$loginOrEmail,role:"Admin"}')" >/dev/null 2>&1 || true
}

ensure_student_datasource() {
  local org_id="$1"
  local username="$2"
  local password="$3"
  local existing

  existing="$(grafana_api GET "/api/datasources/name/PostgreSQL" "" "$org_id" 2>/dev/null | jq -r '.id // empty' || true)"
  if [[ -n "$existing" ]]; then
    return
  fi

  grafana_api POST "/api/datasources" "$(jq -cn \
    --arg db "$POSTGRES_DB" \
    --arg user "$username" \
    --arg password "$password" \
    '{
      name:"PostgreSQL",
      type:"grafana-postgresql-datasource",
      access:"proxy",
      url:"timescaledb:5432",
      database:$db,
      user:$user,
      secureJsonData:{password:$password},
      jsonData:{sslmode:"disable",postgresVersion:1600,timescaledb:true},
      isDefault:true
    }')" "$org_id" >/dev/null
}

echo "Provisioning ${STUDENT_COUNT} student accounts..."
for i in $(seq 1 "$STUDENT_COUNT"); do
  username="student${i}"
  schema="s_student${i}"
  org="org_student${i}"
  password="$(password_for "$username")"

  ensure_csv_row "$username" "$password" "$schema" "$org"
  ensure_pg_student "$username" "$password" "$schema"
  user_id="$(ensure_grafana_user "$username" "$password")"
  org_id="$(ensure_grafana_org "$org")"
  ensure_org_membership "$org_id" "$username"

  if [[ "$PREPROVISION_STUDENT_DATASOURCES" == "true" ]]; then
    ensure_student_datasource "$org_id" "$username" "$password"
  fi

  echo "Provisioned ${username} with PostgreSQL schema ${schema} and Grafana org ${org}."
done

echo
echo "Student credential file written to: ${CREDENTIAL_FILE}"
echo "This file is gitignored. Distribute it through your course's secure channel."
