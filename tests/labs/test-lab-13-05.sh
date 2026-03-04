#!/usr/bin/env bash
# test-lab-13-05.sh — Lab 13-05: Advanced Integration
# Module 13: Odoo ERP  ·  INT-05: Odoo↔Keycloak OIDC
# Services: PostgreSQL · Redis · OpenLDAP · Keycloak · WireMock (Snipe-IT/SuiteCRM-mock) · Mailhog · Odoo
# Ports:    Odoo:8370  Gevent:8371  WireMock:8372  KC:8470  LDAP:3896  MH:8670
# INT-05:   LDAP seed (odooadmin/odoouser1/odoouser2) · KC LDAP federation · Odoo OIDC provider · token issuance
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

# ── PHASE 3: Functional Tests — WireMock + LDAP Seed ─────────────────────────
section "Phase 3: Functional Tests — Advanced Integration (INT-05)"

# ── 3a: Register WireMock stubs for Snipe-IT REST + SuiteCRM JSONRPC ──────────
info "Registering WireMock stubs for Snipe-IT and SuiteCRM APIs..."

# Snipe-IT hardware list stub
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X POST "${MOCK_URL}/__admin/mappings" \
  -H "Content-Type: application/json" \
  -d '{
    "request": {"method": "GET", "url": "/api/v1/hardware"},
    "response": {"status": 200,
                 "body": "{\"total\":3,\"rows\":[{\"id\":1,\"name\":\"Laptop-001\",\"status\":{\"id\":2,\"name\":\"Ready to Deploy\"}}]}",
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
                 "body": "{\"total\":5,\"rows\":[{\"id\":1,\"name\":\"Admin User\",\"username\":\"admin\",\"email\":\"admin@lab.local\"}]}",
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
                 "body": "{\"jsonrpc\":\"2.0\",\"result\":{\"records\":[{\"id\":\"acct-001\",\"name\":\"Acme Corp\"}]}}",
                 "headers": {"Content-Type": "application/json"}}
  }' || echo "000")
if [ "${HTTP_STATUS}" = "201" ]; then
  pass "WireMock stub: SuiteCRM JSONRPC /jsonrpc registered"
else
  fail "WireMock stub: SuiteCRM JSONRPC failed (status: ${HTTP_STATUS})"
fi

# ── 3b: LDAP seed verification ────────────────────────────────────────────────
info "Verifying LDAP seed (odoo-int-ldap-seed) completed successfully..."

# Seed container should have exited 0
SEED_EXIT=$(docker inspect odoo-int-ldap-seed --format '{{.State.ExitCode}}' 2>/dev/null || echo "99")
if [ "${SEED_EXIT}" = "0" ]; then
  pass "odoo-int-ldap-seed exited 0 (seed successful)"
else
  fail "odoo-int-ldap-seed exit code: ${SEED_EXIT} (expected 0)"
fi

# Count seeded users in cn=users,cn=accounts,dc=lab,dc=local
USER_COUNT=$(ldapsearch -x -H ldap://localhost:3896 \
  -b "cn=users,cn=accounts,dc=lab,dc=local" \
  -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
  "(objectClass=inetOrgPerson)" uid 2>/dev/null \
  | grep -c "^uid:" || echo "0")
if [ "${USER_COUNT}" -ge 3 ]; then
  pass "LDAP seed: ${USER_COUNT} users found in cn=users,cn=accounts (expected ≥3)"
else
  fail "LDAP seed: only ${USER_COUNT} users found (expected ≥3)"
fi

# Count seeded groups in cn=groups,cn=accounts,dc=lab,dc=local
GROUP_COUNT=$(ldapsearch -x -H ldap://localhost:3896 \
  -b "cn=groups,cn=accounts,dc=lab,dc=local" \
  -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
  "(objectClass=groupOfNames)" cn 2>/dev/null \
  | grep -c "^cn:" || echo "0")
if [ "${GROUP_COUNT}" -ge 2 ]; then
  pass "LDAP seed: ${GROUP_COUNT} groups found in cn=groups,cn=accounts (expected ≥2)"
else
  fail "LDAP seed: only ${GROUP_COUNT} groups found (expected ≥2)"
fi

# Bind as readonly user and verify odooadmin exists
if ldapsearch -x -H ldap://localhost:3896 \
    -b "cn=users,cn=accounts,dc=lab,dc=local" \
    -D "cn=readonly,dc=lab,dc=local" -w "ReadOnly05!" \
    "(uid=odooadmin)" uid 2>/dev/null | grep -q "uid: odooadmin"; then
  pass "LDAP seed: readonly bind OK, uid=odooadmin found"
else
  fail "LDAP seed: uid=odooadmin not found or readonly bind failed"
fi

# ── 3c: Verify WireMock stub endpoints respond ────────────────────────────────
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

# ── 3d: Integration env vars in Odoo container ───────────────────────────────
if docker exec odoo-i05-app env | grep -q 'SNIPEIT_URL=http://odoo-i05-mock'; then
  pass "SNIPEIT_URL env var set correctly"
else
  fail "SNIPEIT_URL not set in Odoo container"
fi

if docker exec odoo-i05-app env | grep -q 'LDAP_BASE_DN=cn=users,cn=accounts,dc=lab,dc=local'; then
  pass "LDAP_BASE_DN set to FreeIPA-style path (cn=users,cn=accounts,dc=lab,dc=local)"
else
  fail "LDAP_BASE_DN not set to FreeIPA path in Odoo container"
fi

if docker exec odoo-i05-app env | grep -q 'KEYCLOAK_CLIENT_ID=odoo'; then
  pass "KEYCLOAK_CLIENT_ID=odoo env var set correctly"
else
  fail "KEYCLOAK_CLIENT_ID not set in Odoo container"
fi

# ── 3e: Connectivity from Odoo container to WireMock ─────────────────────────
if docker exec odoo-i05-app curl -sf http://odoo-i05-mock:8080/api/v1/hardware \
     -H 'Authorization: Bearer lab-snipeit-token-05' > /dev/null 2>&1; then
  pass "Odoo container → WireMock (Snipe-IT mock) reachable"
else
  fail "Odoo container cannot reach WireMock (Snipe-IT mock)"
fi

# ── 3f: Odoo gevent port ──────────────────────────────────────────────────────
if nc -z localhost 8371 2>/dev/null; then
  pass "Odoo gevent longpolling port 8371 reachable"
else
  warn "Odoo gevent port 8371 not yet reachable (normal during startup)"
fi

# ── PHASE 4: Keycloak LDAP Federation (INT-05) ────────────────────────────────
section "Phase 4: Keycloak LDAP Federation (INT-05)"

KC_BASE="http://localhost:8470"
KC_REALM="it-stack"

# 4a: Get Keycloak admin token
info "Authenticating to Keycloak admin..."
KC_TOKEN=$(curl -sf -X POST "${KC_BASE}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli&grant_type=password&username=admin&password=Admin05!" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
if [ -n "${KC_TOKEN}" ]; then
  pass "Keycloak admin token acquired"
else
  fail "Keycloak admin token not acquired — subsequent KC tests will fail"
fi

# 4b: Create it-stack realm if absent
HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_BASE}/admin/realms/${KC_REALM}" \
  -H "Authorization: Bearer ${KC_TOKEN}" || echo "000")
if [ "${HTTP_STATUS}" = "200" ]; then
  pass "Keycloak realm '${KC_REALM}' already exists"
else
  info "Creating Keycloak realm '${KC_REALM}'..."
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"realm\":\"${KC_REALM}\",\"enabled\":true,\"displayName\":\"IT-Stack Lab\"}" \
    || echo "000")
  if [ "${HTTP_STATUS}" = "201" ]; then
    pass "Keycloak realm '${KC_REALM}' created"
  else
    fail "Keycloak realm creation failed (status: ${HTTP_STATUS})"
  fi
fi

# 4c: Create LDAP federation component
info "Registering LDAP federation component in Keycloak..."
EXISTING_LDAP=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; comps=json.load(sys.stdin); print(next((c['id'] for c in comps if c.get('name')=='odoo-lab-ldap'),''))" \
  2>/dev/null || echo "")
if [ -n "${EXISTING_LDAP}" ]; then
  pass "Keycloak LDAP federation 'odoo-lab-ldap' already registered (ID: ${EXISTING_LDAP})"
else
  LDAP_PAYLOAD=$(cat <<'LDAP_PAYLOAD_EOF'
{
  "name": "odoo-lab-ldap",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "config": {
    "vendor":               ["rhds"],
    "connectionUrl":        ["ldap://odoo-i05-ldap:389"],
    "bindDn":               ["cn=readonly,dc=lab,dc=local"],
    "bindCredential":       ["ReadOnly05!"],
    "usersDn":              ["cn=users,cn=accounts,dc=lab,dc=local"],
    "userObjectClasses":    ["inetOrgPerson"],
    "usernameLDAPAttribute":["uid"],
    "uuidLDAPAttribute":    ["uid"],
    "rdnLDAPAttribute":     ["uid"],
    "searchScope":          ["1"],
    "authType":             ["simple"],
    "enabled":              ["true"],
    "trustEmail":           ["true"],
    "syncRegistrations":    ["true"],
    "fullSyncPeriod":       ["-1"],
    "changedSyncPeriod":    ["-1"],
    "importEnabled":        ["true"],
    "batchSizeForSync":     ["1000"]
  }
}
LDAP_PAYLOAD_EOF
)
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KC_REALM}/components" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${LDAP_PAYLOAD}" || echo "000")
  if [ "${HTTP_STATUS}" = "201" ]; then
    pass "Keycloak LDAP federation 'odoo-lab-ldap' created"
    EXISTING_LDAP=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/components?type=org.keycloak.storage.UserStorageProvider" \
      -H "Authorization: Bearer ${KC_TOKEN}" \
      | python3 -c "import sys,json; comps=json.load(sys.stdin); print(next((c['id'] for c in comps if c.get('name')=='odoo-lab-ldap'),''))" \
      2>/dev/null || echo "")
  else
    fail "Keycloak LDAP federation creation failed (status: ${HTTP_STATUS})"
  fi
fi

# 4d: Trigger full LDAP sync
if [ -n "${EXISTING_LDAP}" ]; then
  info "Triggering full LDAP sync in Keycloak..."
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KC_REALM}/user-storage/${EXISTING_LDAP}/sync?action=triggerFullSync" \
    -H "Authorization: Bearer ${KC_TOKEN}" || echo "000")
  if [ "${HTTP_STATUS}" = "200" ]; then
    pass "Keycloak LDAP full sync triggered"
  else
    fail "Keycloak LDAP full sync failed (status: ${HTTP_STATUS})"
  fi
fi

# 4e: Verify synced users in Keycloak
info "Verifying synced users in Keycloak..."
sleep 5
KC_USER_COUNT=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/users?max=100" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
if [ "${KC_USER_COUNT}" -ge 3 ]; then
  pass "Keycloak: ${KC_USER_COUNT} users synced from LDAP (expected ≥3)"
else
  fail "Keycloak: only ${KC_USER_COUNT} users synced from LDAP (expected ≥3)"
fi

# Verify odooadmin in KC
ODOO_ADMIN_IN_KC=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/users?username=odooadmin&exact=true" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; users=json.load(sys.stdin); print(users[0]['username'] if users else '')" \
  2>/dev/null || echo "")
if [ "${ODOO_ADMIN_IN_KC}" = "odooadmin" ]; then
  pass "Keycloak: odooadmin present after LDAP sync"
else
  fail "Keycloak: odooadmin not found after LDAP sync"
fi

# ── PHASE 5: Keycloak OIDC Client + Odoo Provider Verification (INT-05) ──────
section "Phase 5: Keycloak OIDC Client + Odoo OIDC Provider (INT-05)"

# 5a: Assert KC OIDC discovery URL accessible
KC_DISC_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
  "${KC_BASE}/realms/${KC_REALM}/.well-known/openid-configuration" || echo "000")
if [ "${KC_DISC_STATUS}" = "200" ]; then
  pass "Keycloak OIDC discovery URL responds HTTP 200"
else
  fail "Keycloak OIDC discovery URL not accessible (status: ${KC_DISC_STATUS})"
fi

# 5b: Register 'odoo' OIDC client in KC if absent
EXISTING_CLIENT=$(curl -sf "${KC_BASE}/admin/realms/${KC_REALM}/clients?clientId=odoo" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  | python3 -c "import sys,json; clients=json.load(sys.stdin); print(clients[0]['id'] if clients else '')" \
  2>/dev/null || echo "")
if [ -n "${EXISTING_CLIENT}" ]; then
  pass "Keycloak OIDC client 'odoo' already registered"
else
  info "Registering Keycloak OIDC client 'odoo'..."
  HTTP_STATUS=$(curl -sf -o /dev/null -w "%{http_code}" \
    -X POST "${KC_BASE}/admin/realms/${KC_REALM}/clients" \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    -d '{
      "clientId": "odoo",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "redirectUris": ["http://localhost:8370/*"],
      "webOrigins": ["http://localhost:8370"],
      "secret": "odoo-lab05-secret",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": true
    }' || echo "000")
  if [ "${HTTP_STATUS}" = "201" ]; then
    pass "Keycloak OIDC client 'odoo' created"
  else
    fail "Keycloak OIDC client 'odoo' creation failed (status: ${HTTP_STATUS})"
  fi
fi

# 5c: Authenticate to Odoo and check auth.oauth.provider via JSON-RPC
info "Checking Odoo auth.oauth.provider configuration via JSON-RPC..."
ODOO_SESSION=$(curl -sf -c /tmp/odoo-lab05-cookies.txt \
  -X POST "http://localhost:8370/web/session/authenticate" \
  -H "Content-Type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"id\":1,\"params\":{\"db\":\"odoo\",\"login\":\"admin\",\"password\":\"OdooLab05!\"}}" \
  | python3 -c "import sys,json; r=json.load(sys.stdin); print(r.get('result',{}).get('uid',''))" \
  2>/dev/null || echo "")
if [ -n "${ODOO_SESSION}" ]; then
  pass "Odoo JSON-RPC authentication successful (uid=${ODOO_SESSION})"
else
  fail "Odoo JSON-RPC authentication failed — skipping provider checks"
fi

if [ -n "${ODOO_SESSION}" ]; then
  KC_PROVIDER_COUNT=$(curl -sf -b /tmp/odoo-lab05-cookies.txt \
    -X POST "http://localhost:8370/web/dataset/call_kw" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"id\":2,\"params\":{\"model\":\"auth.oauth.provider\",\"method\":\"search_read\",\"args\":[[]],\"kwargs\":{\"fields\":[\"id\",\"name\",\"client_id\",\"enabled\"],\"limit\":50}}}" \
    | python3 -c "import sys,json; r=json.load(sys.stdin); providers=r.get('result',[]); print(len(providers))" \
    2>/dev/null || echo "0")
  if [ "${KC_PROVIDER_COUNT}" -ge 1 ]; then
    pass "Odoo: ${KC_PROVIDER_COUNT} OAuth provider(s) registered in auth.oauth.provider"
  else
    warn "Odoo: no OAuth providers found in auth.oauth.provider (auth_oauth module may not be installed yet)"
  fi
  rm -f /tmp/odoo-lab05-cookies.txt
fi

# ── PHASE 6: OIDC Token Issuance (INT-05) ────────────────────────────────────
section "Phase 6: OIDC Token Issuance (INT-05)"

# 6a: Obtain OIDC token for odooadmin from Keycloak
info "Requesting OIDC token from Keycloak for odooadmin..."
OIDC_RESP=$(curl -sf \
  -X POST "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/token" \
  -d "client_id=odoo" \
  -d "client_secret=odoo-lab05-secret" \
  -d "grant_type=password" \
  -d "username=odooadmin" \
  -d "password=Lab05Password!" \
  -d "scope=openid profile email" \
  2>/dev/null || echo "")
OIDC_ACCESS=$(echo "${OIDC_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null || echo "")
OIDC_ID_TOKEN=$(echo "${OIDC_RESP}" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id_token',''))" 2>/dev/null || echo "")

if [ -n "${OIDC_ACCESS}" ]; then
  pass "OIDC access token obtained for odooadmin"
else
  fail "OIDC token not obtained for odooadmin — KC LDAP sync or client config issue"
fi

# 6b: Call userinfo endpoint with token to verify claims
if [ -n "${OIDC_ACCESS}" ]; then
  KC_SUB=$(curl -sf \
    "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/userinfo" \
    -H "Authorization: Bearer ${OIDC_ACCESS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('sub',''))" 2>/dev/null || echo "")
  if [ -n "${KC_SUB}" ]; then
    pass "KC userinfo: sub claim present (${KC_SUB})"
  else
    fail "KC userinfo: sub claim missing"
  fi

  KC_USERNAME=$(curl -sf \
    "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/userinfo" \
    -H "Authorization: Bearer ${OIDC_ACCESS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('preferred_username',''))" 2>/dev/null || echo "")
  if [ "${KC_USERNAME}" = "odooadmin" ]; then
    pass "KC userinfo: preferred_username=odooadmin confirmed"
  else
    fail "KC userinfo: preferred_username='${KC_USERNAME}' (expected odooadmin)"
  fi
fi

# 6c: Introspect token via Keycloak
if [ -n "${OIDC_ACCESS}" ]; then
  ACTIVE=$(curl -sf \
    -X POST "${KC_BASE}/realms/${KC_REALM}/protocol/openid-connect/token/introspect" \
    -d "client_id=odoo" \
    -d "client_secret=odoo-lab05-secret" \
    -d "token=${OIDC_ACCESS}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('active',''))" 2>/dev/null || echo "")
  if [ "${ACTIVE}" = "True" ] || [ "${ACTIVE}" = "true" ]; then
    pass "OIDC token introspection: active=true"
  else
    fail "OIDC token introspection: active='${ACTIVE}' (expected true)"
  fi
fi

# ── Results ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}============================================================${NC}"
echo -e "  Lab ${LAB_ID} Complete — INT-05: Odoo↔Keycloak OIDC"
echo -e "  ${GREEN}PASS: ${PASS}${NC} | ${RED}FAIL: ${FAIL}${NC}"
echo -e "${CYAN}============================================================${NC}"

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
