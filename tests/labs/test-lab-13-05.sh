#!/usr/bin/env bash
# test-lab-13-05.sh — Lab 13-05: Advanced Integration
# Module 13: Odoo ERP
# Services: PostgreSQL · Redis · OpenLDAP · Keycloak · WireMock (Snipe-IT/SuiteCRM-mock) · Mailhog · Odoo
# Ports:    Odoo:8370  Gevent:8371  WireMock:8372  KC:8470  LDAP:3896  MH:8670
set -euo pipefail

LAB_ID="13-05"
LAB_NAME="Advanced Integration"
MODULE="odoo"
COMPOSE_FILE="docker/docker-compose.integration.yml"
MOCK_URL="http://localhost:8372"
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
echo -e "${CYAN}  Odoo ↔ Snipe-IT REST (WireMock) + SuiteCRM customer sync${NC}"
echo -e "${CYAN}============================================================${NC}"
echo ""

# ── PHASE 1: Setup ────────────────────────────────────────────────────────────
section "Phase 1: Setup"
docker compose -f "${COMPOSE_FILE}" up -d
info "Waiting 60s for integration stack to initialize..."
sleep 60

# ── PHASE 2: Health Checks ────────────────────────────────────────────────────
section "Phase 2: Health Checks"

for svc in odoo-i05-db odoo-i05-redis odoo-i05-ldap odoo-i05-kc odoo-i05-mock odoo-i05-mail odoo-i05-app; do
  if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
    pass "Container ${svc} running"
  else
    fail "Container ${svc} not running"
  fi
done

if docker exec odoo-i05-db pg_isready -U odoo 2>/dev/null; then
  pass "PostgreSQL accepting connections"
else
  fail "PostgreSQL not responding"
fi

if docker exec odoo-i05-redis redis-cli ping 2>/dev/null | grep -q 'PONG'; then
  pass "Redis PONG"
else
  fail "Redis not responding"
fi

if curl -sf "${MOCK_URL}/__admin/health" > /dev/null 2>&1; then
  pass "WireMock admin health endpoint accessible"
else
  fail "WireMock not accessible at ${MOCK_URL}"
fi

if curl -sf http://localhost:8370/web/login > /dev/null 2>&1; then
  pass "Odoo web login accessible (:8370)"
else
  fail "Odoo web not accessible (:8370)"
fi

# ── PHASE 3: Functional Tests — Integration ───────────────────────────────────
section "Phase 3: Functional Tests — Advanced Integration"

# ── 3a: WireMock stubs for Snipe-IT REST + SuiteCRM JSONRPC ───────────────
info "Registering WireMock stubs for Snipe-IT and SuiteCRM APIs..."

# Snipe-IT hardware list stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "url": "/api/v1/hardware"},
    "response": {"status": 200,
                 "body": "{\\"total\\":3,\\"rows\\":[{\\"id\\":1,\\"name\\":\\"Laptop-001\\",\\"status\\":{\\"id\\":2,\\"name\\":\\"Ready to Deploy\\"}}]}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: Snipe-IT GET /api/v1/hardware registered"
else
  fail "WireMock stub: Snipe-IT hardware failed (status: ${HTTP_STATUS})"
fi

# Snipe-IT users stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "url": "/api/v1/users"},
    "response": {"status": 200,
                 "body": "{\\"total\\":5,\\"rows\\":[{\\"id\\":1,\\"name\\":\\"Admin User\\",\\"username\\":\\"admin\\",\\"email\\":\\"admin@lab.local\\"}]}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: Snipe-IT GET /api/v1/users registered"
else
  fail "WireMock stub: Snipe-IT users failed (status: ${HTTP_STATUS})"
fi

# SuiteCRM customer sync stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "POST", "url": "/jsonrpc"},
    "response": {"status": 200,
                 "body": "{\\"jsonrpc\\":\\"2.0\\",\\"result\\":{\\"records\\":[{\\"id\\":\\"acct-001\\",\\"name\\":\\"Acme Corp\\"}]}}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: SuiteCRM JSONRPC /jsonrpc registered"
else
  fail "WireMock stub: SuiteCRM JSONRPC failed (status: ${HTTP_STATUS})"
fi

# ── 3b: Verify WireMock stubs respond correctly ─────────────────────────────
info "Verifying integration mock endpoints..."

if curl -sf "${MOCK_URL}/api/v1/hardware" \
     -H "Authorization: Bearer lab-snipeit-token-05" \
     | grep -q 'Laptop-001'; then
  pass "WireMock Snipe-IT hardware endpoint responds correctly"
else
  fail "WireMock Snipe-IT hardware endpoint not responding"
fi

if curl -sf "${MOCK_URL}/api/v1/users" | grep -q 'admin@lab.local'; then
  pass "WireMock Snipe-IT users endpoint responds correctly"
else
  fail "WireMock Snipe-IT users endpoint not responding"
fi

# ── 3c: Integration env vars in Odoo container ──────────────────────────────
if docker exec odoo-i05-app env | grep -q 'SNIPEIT_URL=http://odoo-i05-mock'; then
  pass "SNIPEIT_URL env var set correctly"
else
  fail "SNIPEIT_URL not set in Odoo container"
fi

if docker exec odoo-i05-app env | grep -q 'SNIPEIT_API_TOKEN=lab-snipeit-token-05'; then
  pass "SNIPEIT_API_TOKEN env var set correctly"
else
  fail "SNIPEIT_API_TOKEN not set in Odoo container"
fi

if docker exec odoo-i05-app env | grep -q 'LDAP_HOST=odoo-i05-ldap'; then
  pass "LDAP_HOST env var set correctly"
else
  fail "LDAP_HOST not set in Odoo container"
fi

# ── 3d: Connectivity from Odoo container to WireMock ────────────────────────
if docker exec odoo-i05-app curl -sf http://odoo-i05-mock:8080/api/v1/hardware \
     -H 'Authorization: Bearer lab-snipeit-token-05' > /dev/null 2>&1; then
  pass "Odoo container → WireMock (Snipe-IT mock) reachable"
else
  fail "Odoo container cannot reach WireMock (Snipe-IT mock)"
fi

# ── 3e: Odoo gevent port ─────────────────────────────────────────────────────
if nc -z localhost 8371 2>/dev/null; then
  pass "Odoo gevent longpolling port 8371 reachable"
else
  warn "Odoo gevent port 8371 not yet reachable (normal during startup)"
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
# test-lab-13-05.sh — Lab 13-05: Advanced Integration
# Module 13: Odoo ERP and business management
# odoo integrated with full IT-Stack ecosystem
set -euo pipefail

LAB_ID="13-05"
LAB_NAME="Advanced Integration"
MODULE="odoo"
COMPOSE_FILE="docker/docker-compose.integration.yml"
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
info "Phase 3: Functional Tests (Lab 05 — Advanced Integration)"

# TODO: Add module-specific functional tests here
# Example:
# if curl -sf http://localhost:8069/health > /dev/null 2>&1; then
#     pass "Health endpoint responds"
# else
#     fail "Health endpoint not reachable"
# fi

warn "Functional tests for Lab 13-05 pending implementation"

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
