#!/usr/bin/env bash
# test-lab-13-01.sh — Odoo Lab 01: Standalone
# Module 13 | Lab 01 | Tests: basic Odoo ERP functionality in isolation
set -euo pipefail

COMPOSE_FILE="$(dirname "$0")/../docker/docker-compose.standalone.yml"
CLEANUP=true
for arg in "$@"; do [[ "$arg" == "--no-cleanup" ]] && CLEANUP=false; done

WEB_PORT=8303
DB_USER="odoo"
DB_PASS="OdooLab01!"

PASS=0; FAIL=0
pass() { echo "[PASS] $1"; ((PASS++)) || true; }
fail() { echo "[FAIL] $1"; ((FAIL++)) || true; }
section() { echo ""; echo "=== $1 ==="; }

cleanup() {
  if [[ "$CLEANUP" == "true" ]]; then
    echo "Cleaning up..."
    docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

section "Starting Lab 01 Standalone Stack"
docker compose -f "$COMPOSE_FILE" up -d
echo "Waiting for PostgreSQL and Odoo to initialize..."

section "PostgreSQL Health Check"
for i in $(seq 1 30); do
  status=$(docker inspect odoo-s01-db --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break; sleep 5
done
[[ "$(docker inspect odoo-s01-db --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "PostgreSQL healthy" || fail "PostgreSQL not healthy"

section "Odoo App Health Check"
for i in $(seq 1 60); do
  status=$(docker inspect odoo-s01-app --format '{{.State.Health.Status}}' 2>/dev/null || echo "waiting")
  [[ "$status" == "healthy" ]] && break
  echo "  Waiting for Odoo ($i/60)..."
  sleep 10
done
[[ "$(docker inspect odoo-s01-app --format '{{.State.Health.Status}}')" == "healthy" ]] && pass "Odoo app healthy" || fail "Odoo app not healthy"

section "Odoo Web UI"
http_code=$(curl -so /dev/null -w "%{http_code}" -L "http://localhost:${WEB_PORT}/" 2>/dev/null || echo "000")
[[ "$http_code" =~ ^(200|303|302)$ ]] && pass "Odoo web accessible (HTTP $http_code)" || fail "Odoo web returned HTTP $http_code"

curl -sf -L "http://localhost:${WEB_PORT}/" 2>/dev/null | grep -qi "odoo\|login\|openerp\|web client" && pass "Odoo web page content OK" || fail "Odoo web page content unexpected"

section "Odoo Health Endpoint"
health_resp=$(curl -sf "http://localhost:${WEB_PORT}/web/health" 2>/dev/null || echo "")
if echo "$health_resp" | grep -qiE '"status"\s*:\s*"pass"|"ok"|\{'; then
  pass "Odoo /web/health endpoint responding"
else
  # Older Odoo versions may not have /web/health — check Odoo root
  curl -sf "http://localhost:${WEB_PORT}/" | grep -qi "odoo" && pass "Odoo web accessible (health endpoint alt check)" || fail "Odoo health check failed"
fi

section "Odoo JSON-RPC API"
api_resp=$(curl -sf -X POST "http://localhost:${WEB_PORT}/web/dataset/call_kw" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"call","id":1,"params":{"model":"res.lang","method":"search_read","args":[[]],"kwargs":{"fields":["name"],"limit":1}}}' \
  2>/dev/null || echo "")
echo "$api_resp" | grep -q '"result"' && pass "Odoo JSON-RPC API responding" || {
  echo "$api_resp" | grep -q '"error"' && pass "Odoo JSON-RPC API responding (auth error expected)" || fail "Odoo JSON-RPC API not responding"
}

section "Database Connectivity"
docker exec odoo-s01-db psql -U "${DB_USER}" -l 2>/dev/null | grep -q "odoo\|postgres" && pass "PostgreSQL accessible as odoo user" || fail "PostgreSQL connection failed"

section "Container Configuration"
restart_policy=$(docker inspect odoo-s01-app --format '{{.HostConfig.RestartPolicy.Name}}')
[[ "$restart_policy" == "unless-stopped" ]] && pass "Restart policy: unless-stopped" || fail "Unexpected restart policy: $restart_policy"

db_host=$(docker inspect odoo-s01-app --format '{{range .Config.Env}}{{println .}}{{end}}' | grep "^HOST=" | cut -d= -f2)
[[ "$db_host" == "odoo-s01-db" ]] && pass "HOST env var set correctly" || fail "HOST env var not set (got: $db_host)"

section "Named Volumes"
docker volume ls | grep -q "odoo-s01-db-data" && pass "Volume odoo-s01-db-data exists" || fail "Volume odoo-s01-db-data missing"
docker volume ls | grep -q "odoo-s01-data" && pass "Volume odoo-s01-data exists" || fail "Volume odoo-s01-data missing"

echo ""
echo "================================================"
echo "Lab 01 Results: ${PASS} passed, ${FAIL} failed"
echo "================================================"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1