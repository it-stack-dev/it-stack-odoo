#!/usr/bin/env bash
# test-lab-13-03.sh — Lab 13-03: Advanced Features
# Module 13: Odoo ERP
# Tests: multi-worker + gevent longpolling port + Redis + resource limits
set -euo pipefail

LAB_ID="13-03"
LAB_NAME="Advanced Features"
MODULE="odoo"
COMPOSE_FILE="docker/docker-compose.advanced.yml"
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

info "Waiting for PostgreSQL (up to 60s)..."
for i in $(seq 1 12); do
  if docker exec odoo-a03-db pg_isready -U odoo -d odoo_lab03 > /dev/null 2>&1; then
    pass "PostgreSQL healthy"; break
  fi
  [[ $i -eq 12 ]] && fail "PostgreSQL timed out"
  sleep 5
done

info "Waiting for Redis (up to 30s)..."
for i in $(seq 1 6); do
  if docker exec odoo-a03-redis redis-cli ping 2>/dev/null | grep -q PONG; then
    pass "Redis healthy (PONG)"; break
  fi
  [[ $i -eq 6 ]] && fail "Redis not responding"
  sleep 5
done

info "Waiting for Mailhog (up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8630/api/v2/messages > /dev/null 2>&1; then
    pass "Mailhog reachable on :8630"; break
  fi
  [[ $i -eq 12 ]] && fail "Mailhog not reachable on :8630"
  sleep 5
done

info "Waiting for Odoo web (up to 2 min)..."
for i in $(seq 1 24); do
  if curl -sf http://localhost:8330/web/health 2>/dev/null | grep -q 'ok\|pass'; then
    pass "Odoo /web/health OK on :8330"; break
  fi
  [[ $i -eq 24 ]] && fail "Odoo not reachable on :8330"
  sleep 5
done

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
section "Phase 3: Functional Tests"

# Containers
for cname in odoo-a03-db odoo-a03-redis odoo-a03-mail odoo-a03-app; do
  if docker inspect "${cname}" --format '{{.State.Status}}' 2>/dev/null | grep -q running; then
    pass "${cname} running"
  else
    fail "${cname} not running"
  fi
done

# Gevent longpolling port
info "Waiting for Odoo gevent longpoll on :8331 (up to 60s)..."
for i in $(seq 1 12); do
  if curl -sf http://localhost:8331/ > /dev/null 2>&1; then
    pass "Odoo gevent longpolling reachable on :8331"; break
  fi
  [[ $i -eq 12 ]] && fail "Odoo gevent longpolling not reachable on :8331"
  sleep 5
done

# Multi-worker: multiple odoo processes
WORKER_COUNT=$(docker exec odoo-a03-app pgrep -c 'python\|odoo' 2>/dev/null || echo 0)
if [[ "${WORKER_COUNT:-0}" -ge 2 ]]; then
  pass "Odoo running ${WORKER_COUNT} worker processes"
else
  fail "Odoo has only ${WORKER_COUNT:-0} processes (expected ≥2 with --workers=2)"
fi

# Redis connectivity from app
if docker exec odoo-a03-app redis-cli -h odoo-a03-redis ping 2>/dev/null | grep -q PONG; then
  pass "App connects to Redis"
else
  fail "App cannot reach Redis"
fi

# /web/health
if curl -sf http://localhost:8330/web/health | grep -q 'ok\|pass'; then
  pass "Odoo /web/health endpoint OK"
else
  fail "Odoo /web/health endpoint failed"
fi

# JSON-RPC
DB_LIST=$(curl -sf -X POST http://localhost:8330/web/database/get_list \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","method":"call","params":{}}' 2>/dev/null || echo "{}")
if echo "${DB_LIST}" | grep -q 'result'; then
  pass "Odoo JSON-RPC /web/database/get_list OK"
else
  fail "Odoo JSON-RPC not responding"
fi

# Resource limits
MEM_LIMIT=$(docker inspect odoo-a03-app --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
if [[ "${MEM_LIMIT:-0}" -gt 0 ]]; then
  pass "Memory limit set on odoo-a03-app (${MEM_LIMIT} bytes)"
else
  fail "No memory limit on odoo-a03-app"
fi

# CPU limit
CPU_LIMIT=$(docker inspect odoo-a03-app --format '{{.HostConfig.NanoCpus}}' 2>/dev/null || echo 0)
if [[ "${CPU_LIMIT:-0}" -gt 0 ]]; then
  pass "CPU limit set on odoo-a03-app"
else
  fail "No CPU limit on odoo-a03-app"
fi

# Mailhog API
if curl -sf http://localhost:8630/api/v2/messages | grep -q 'total\|items'; then
  pass "Mailhog API valid"
else
  fail "Mailhog API invalid"
fi

# Volumes
for vol in odoo-a03-db-data odoo-a03-redis-data odoo-a03-data odoo-a03-addons; do
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