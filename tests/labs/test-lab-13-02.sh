#!/usr/bin/env bash
# test-lab-13-02.sh — Lab 13-02: External Dependencies
# Module 13: Odoo ERP
# Tests: external PostgreSQL + Redis cache/sessions + Mailhog SMTP relay
set -euo pipefail

LAB_ID="13-02"
LAB_NAME="External Dependencies"
MODULE="odoo"
COMPOSE_FILE="docker/docker-compose.lan.yml"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
section() { echo -e "\n${CYAN}── $1 ──${NC}"; }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }

CLEANUP=true
[[ "${1:-}" == "--no-cleanup" ]] && CLEANUP=false

cleanup() {
  if [[ "${CLEANUP}" == "true" ]]; then
    info "Cleaning up..."
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}========================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}========================================${NC}"

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

info "Waiting for external PostgreSQL (odoo-l02-db, up to 60s)..."
for i in $(seq 1 12); do
  if docker exec odoo-l02-db pg_isready -U odoo -d odoo_lab02 > /dev/null 2>&1; then
    pass "External PostgreSQL healthy"; break
  fi
  [[ $i -eq 12 ]] && fail "External PostgreSQL timed out"
  sleep 5
done

info "Waiting for Redis (odoo-l02-redis, up to 30s)..."
for i in $(seq 1 6); do
  if docker exec odoo-l02-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    pass "Redis healthy (PONG)"; break
  fi
  [[ $i -eq 6 ]] && fail "Redis not responding"
  sleep 5
done

info "Waiting for Mailhog (odoo-l02-mail, up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8612/api/v2/messages > /dev/null 2>&1; then
    pass "Mailhog UI reachable on :8612"; break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog not reachable on :8612"
  sleep 5
done

info "Waiting for Odoo (up to 2 min)..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:8312/web/health 2>/dev/null | grep -q 'ok\|pass'; then
    pass "Odoo /web/health returns ok on :8312"; break
  fi
  [[ $i -eq 24 ]] && fail "Odoo not reachable on :8312"
  sleep 5
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# Container states
for cname in odoo-l02-db odoo-l02-redis odoo-l02-mail odoo-l02-app; do
  if docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    pass "${cname} running"
  else
    fail "${cname} not running"
  fi
done

# External DB connectivity from app
if docker exec odoo-l02-app psql -h odoo-l02-db -U odoo -d odoo_lab02 \
     -c "SELECT 1;" > /dev/null 2>&1; then
  pass "App connects to external PostgreSQL (odoo_lab02)"
else
  fail "App cannot connect to external PostgreSQL"
fi

# Redis connectivity from app
if docker exec odoo-l02-app redis-cli -h odoo-l02-redis ping 2>/dev/null | grep -q PONG; then
  pass "App connects to Redis"
else
  fail "App cannot reach Redis"
fi

# Odoo web health
if curl -sf http://localhost:8312/web/health | grep -q 'ok\|pass'; then
  pass "Odoo /web/health endpoint OK"
else
  fail "Odoo /web/health not OK"
fi

# Odoo JSON-RPC database list
DB_LIST=$(curl -sf -X POST http://localhost:8312/web/database/get_list \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"call","params":{}}' 2>/dev/null || echo "{}")
if echo "${DB_LIST}" | grep -q 'result\|odoo'; then
  pass "Odoo JSON-RPC /web/database/get_list responds"
else
  fail "Odoo JSON-RPC not responding"
fi

# Mailhog API
if curl -sf http://localhost:8612/api/v2/messages | grep -q 'total\|items'; then
  pass "Mailhog API returns valid JSON"
else
  fail "Mailhog API not valid"
fi

# Environment variables
for envvar in HOST PORT USER PASSWORD; do
  if docker exec odoo-l02-app printenv "${envvar}" > /dev/null 2>&1; then
    pass "Env var ${envvar} set"
  else
    fail "Env var ${envvar} missing"
  fi
done

# Volumes
for vol in odoo-l02-db-data odoo-l02-redis-data odoo-l02-data odoo-l02-addons; do
  if docker volume ls --format '{{.Name}}' | grep -q "${vol}"; then
    pass "Volume ${vol} exists"
  else
    fail "Volume ${vol} missing"
  fi
done

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}========================================${NC}"
echo " Lab ${LAB_ID} Results"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}========================================${NC}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0