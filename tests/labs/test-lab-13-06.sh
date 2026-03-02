#!/usr/bin/env bash
# test-lab-13-06.sh — Lab 13-06: Production Deployment
# Module 13: Odoo ERP
# Services: PostgreSQL · Redis · OpenLDAP · Keycloak · Mailhog · Odoo (workers=2, longpolling)
# Ports:    Web:8390  Gevent:8391  KC:8490  LDAP:3900  MH:8690
set -euo pipefail

LAB_ID="13-06"
LAB_NAME="Production Deployment"
MODULE="odoo"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0
CLEANUP=true

for arg in "$@"; do [ "$arg" = "--no-cleanup" ] && CLEANUP=false; done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

pass()    { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail()    { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}── $1 ──${NC}"; }

cleanup() {
  if [ "${CLEANUP}" = "true" ]; then
    docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo -e "${CYAN}============================================================${NC}"
echo -e "${CYAN}  Lab ${LAB_ID}: ${LAB_NAME} — ${MODULE}${NC}"
echo -e "${CYAN}  Production: workers=2, longpolling, Redis, resource limits${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 75s for production stack to initialize..."
sleep 75

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in odoo-p06-db odoo-p06-redis odoo-p06-ldap odoo-p06-kc odoo-p06-mail odoo-p06-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec odoo-p06-db pg_isready -U odoo 2>/dev/null; then
  pass "PostgreSQL accepting connections"
else
  fail "PostgreSQL not responding"
fi

if docker exec odoo-p06-redis redis-cli ping 2>/dev/null | grep -q 'PONG'; then
  pass "Redis PONG"
else
  fail "Redis not responding"
fi

if curl -sf http://localhost:8490/realms/master > /dev/null 2>&1; then
  pass "Keycloak reachable (:8490)"
else
  fail "Keycloak not reachable (:8490)"
fi

if curl -sf http://localhost:8390/web/login > /dev/null 2>&1; then
  pass "Odoo web login accessible (:8390)"
else
  fail "Odoo web not accessible (:8390)"
fi

# ── PHASE 3: Functional Tests — Production Grade ─────────────────────────────
section "Phase 3: Functional Tests — Production Deployment"

# ── 3a: Compose config validation ───────────────────────────────────────────────
if docker compose -f "${COMPOSE_FILE}" config -q 2>/dev/null; then
  pass "Compose file syntax valid"
else
  fail "Compose file syntax error"
fi

# ── 3b: Resource limits ───────────────────────────────────────────────────────────────
MEM_LIMIT=$(docker inspect odoo-p06-app --format '{{.HostConfig.Memory}}' 2>/dev/null || echo 0)
if [ "${MEM_LIMIT}" -gt 0 ] 2>/dev/null; then
  pass "Memory limit set on odoo-p06-app (${MEM_LIMIT} bytes)"
else
  fail "Memory limit not set on odoo-p06-app"
fi

RESTART_POLICY=$(docker inspect odoo-p06-app --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "none")
if [ "${RESTART_POLICY}" = "unless-stopped" ]; then
  pass "Restart policy: unless-stopped"
else
  fail "Restart policy not set to unless-stopped (got: ${RESTART_POLICY})"
fi

# ── 3c: Production env vars ─────────────────────────────────────────────────────
if docker exec odoo-p06-app env | grep -q 'IT_STACK_ENV=production'; then
  pass "IT_STACK_ENV=production set"
else
  fail "IT_STACK_ENV not set to production"
fi

if docker exec odoo-p06-app env | grep -q 'LDAP_HOST=odoo-p06-ldap'; then
  pass "LDAP_HOST configured correctly"
else
  fail "LDAP_HOST not configured"
fi

if docker exec odoo-p06-app env | grep -q 'KEYCLOAK_URL=http://odoo-p06-kc'; then
  pass "KEYCLOAK_URL points to odoo-p06-kc"
else
  fail "KEYCLOAK_URL not configured correctly"
fi

# ── 3d: Database backup test ───────────────────────────────────────────────────
info "Testing database backup (pg_dump)..."
if docker exec odoo-p06-db pg_dump -U odoo odoo > /dev/null 2>&1; then
  pass "Database backup (pg_dump odoo) succeeds"
else
  fail "Database backup (pg_dump odoo) failed"
fi

# ── 3e: Odoo gevent/longpolling port ──────────────────────────────────────────────
if nc -z localhost 8391 2>/dev/null; then
  pass "Odoo gevent longpolling port 8391 reachable"
else
  warn "Odoo gevent port 8391 not yet reachable (normal if workers still starting)"
fi

# ── 3f: Odoo workers mode verification ───────────────────────────────────────────
CMD_LINE=$(docker inspect odoo-p06-app --format '{{.Config.Cmd}}' 2>/dev/null || echo "")
if echo "${CMD_LINE}" | grep -q 'workers'; then
  pass "Odoo workers mode configured in command line"
else
  fail "Odoo workers not present in command line"
fi

# ── 3g: Keycloak admin API ───────────────────────────────────────────────────────
KC_TOKEN=$(curl -sf -X POST http://localhost:8490/realms/master/protocol/openid-connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=admin-cli&grant_type=password&username=admin&password=Admin06!' \
  2>/dev/null | grep -o '"access_token":"[^"]*' | cut -d'"' -f4 || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token obtained"
else
  fail "Keycloak admin token not obtained"
fi

# ── 3h: Restart resilience ─────────────────────────────────────────────────────────
info "Testing PostgreSQL restart resilience..."
docker restart odoo-p06-db > /dev/null 2>&1
sleep 15
if docker exec odoo-p06-db pg_isready -U odoo 2>/dev/null; then
  pass "PostgreSQL recovers after restart"
else
  fail "PostgreSQL did not recover after restart"
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
# test-lab-13-06.sh — Lab 13-06: Production Deployment
# Module 13: Odoo ERP and business management
# odoo in production-grade HA configuration with monitoring
set -euo pipefail

LAB_ID="13-06"
LAB_NAME="Production Deployment"
MODULE="odoo"
COMPOSE_FILE="docker/docker-compose.production.yml"
PASS=0
FAIL=0

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $1"; ((FAIL++)); }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo -e "${CYAN}======================================${NC}"
echo -e "${CYAN} Lab ${LAB_ID}: ${LAB_NAME}${NC}"
echo -e "${CYAN} Module: ${MODULE}${NC}"
echo -e "${CYAN}======================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
info "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 30s for ${MODULE} to initialize..."
sleep 30

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
info "Phase 2: Health Checks"

if docker compose -f "${COMPOSE_FILE}" ps | grep -q "running\|Up"; then
    pass "Container is running"
else
    fail "Container is not running"
fi

# ── PHASE 3: Functional Tests ─────────────────────────────────────────────────
info "Phase 3: Functional Tests (Lab 06 — Production Deployment)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:8069/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 13-06 pending implementation"

# ── PHASE 4: Cleanup ──────────────────────────────────────────────────────────
info "Phase 4: Cleanup"
docker compose -f "${COMPOSE_FILE}" down -v --remove-orphans
info "Cleanup complete"

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}======================================${NC}"
echo -e " Lab ${LAB_ID} Complete"
echo -e " ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}======================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
