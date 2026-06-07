#!/usr/bin/env bash
# ==============================================================================
# init-splunk.sh — Post-startup Splunk initialisation
#
# Run ONCE after "docker compose up -d" to:
#   1. Wait for Splunk REST API to become healthy
#   2. Create the devsecops_security index
#   3. Enable HEC and verify the token
#   4. Print the connection summary
#
# Usage:
#   export SPLUNK_ADMIN_PASSWORD="DevSecOps2026!"
#   export SPLUNK_HEC_TOKEN="b7e2c1d4-a3f8-4e92-8b6d-1234567890ab"
#   bash splunk/init-splunk.sh
# ==============================================================================
set -euo pipefail

SPLUNK_REST="https://localhost:8089"
SPLUNK_PASS="${SPLUNK_ADMIN_PASSWORD:-DevSecOps2026!}"
HEC_TOKEN="${SPLUNK_HEC_TOKEN:-b7e2c1d4-a3f8-4e92-8b6d-1234567890ab}"
INDEX_NAME="devsecops_security"
MAX_WAIT=180

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

step() { echo -e "\n${BOLD}▶ $*${RESET}"; }
ok()   { echo -e "  ${GREEN}✓ $*${RESET}"; }
warn() { echo -e "  ${YELLOW}⚠ $*${RESET}"; }
fail() { echo -e "  ${RED}✗ $*${RESET}"; exit 1; }

splunk_api() {
  # Wrapper for Splunk REST calls — ignores TLS cert on local dev
  curl -sk -u "admin:${SPLUNK_PASS}" "$@"
}

# ── Step 1: Wait for Splunk to be ready ───────────────────────────────────────
step "Waiting for Splunk REST API (max ${MAX_WAIT}s)..."
ELAPSED=0
until splunk_api "${SPLUNK_REST}/services/server/info?output_mode=json" \
    -o /dev/null 2>/dev/null; do
  [[ "$ELAPSED" -ge "$MAX_WAIT" ]] \
    && fail "Splunk did not become ready within ${MAX_WAIT}s. Check: docker logs splunk-devsecops"
  printf "  waiting... %ds\r" "$ELAPSED"
  sleep 5
  ELAPSED=$(( ELAPSED + 5 ))
done
ok "Splunk REST API is responding"

# ── Step 2: Create the devsecops_security index ───────────────────────────────
step "Creating index '${INDEX_NAME}'..."
RESULT=$(splunk_api "${SPLUNK_REST}/services/data/indexes" \
  -d "name=${INDEX_NAME}" \
  -d "datatype=event" \
  -d "maxTotalDataSizeMB=10000" \
  -d "frozenTimePeriodInSecs=604800" \
  -d "output_mode=json" 2>&1)

if echo "$RESULT" | grep -q '"name":"'"${INDEX_NAME}"'"'; then
  ok "Index '${INDEX_NAME}' created"
elif echo "$RESULT" | grep -qi "already exists\|conflict\|409"; then
  warn "Index '${INDEX_NAME}' already exists — skipping"
else
  warn "Unexpected response (may still have worked): $(echo "$RESULT" | head -c 200)"
fi

# ── Step 3: Enable HEC globally ───────────────────────────────────────────────
step "Enabling HTTP Event Collector globally..."
splunk_api "${SPLUNK_REST}/services/data/inputs/http/http" \
  -d "disabled=0" \
  -d "enableSSL=0" \
  -d "port=8088" \
  -d "output_mode=json" -o /dev/null
ok "HEC enabled on port 8088 (no SSL for local dev)"

# ── Step 4: Create / verify HEC token ────────────────────────────────────────
step "Configuring HEC token '${HEC_TOKEN}'..."
TOKEN_RESULT=$(splunk_api "${SPLUNK_REST}/services/data/inputs/http" \
  -d "name=devsecops-hec" \
  -d "token=${HEC_TOKEN}" \
  -d "index=${INDEX_NAME}" \
  -d "sourcetype=aws:waf" \
  -d "output_mode=json" 2>&1)

if echo "$TOKEN_RESULT" | grep -q '"name":"devsecops-hec"'; then
  ok "HEC token created"
elif echo "$TOKEN_RESULT" | grep -qi "already exists\|conflict\|409"; then
  warn "HEC token already exists — token value unchanged"
else
  warn "HEC token response: $(echo "$TOKEN_RESULT" | head -c 200)"
fi

# ── Step 5: Verify HEC is accepting events ────────────────────────────────────
step "Sending test event to verify HEC..."
HEC_RESPONSE=$(curl -s -X POST "http://localhost:8088/services/collector" \
  -H "Authorization: Splunk ${HEC_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"event\":{\"test\":true,\"message\":\"Splunk HEC init check\"},\"index\":\"${INDEX_NAME}\",\"sourcetype\":\"_json\"}")

if echo "$HEC_RESPONSE" | grep -q '"code":0'; then
  ok "HEC accepted test event (code:0 = success)"
else
  warn "HEC response: ${HEC_RESPONSE}"
  warn "If SSL errors occur, check that HEC is configured with enableSSL=0"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════════ SPLUNK READY ════════════════════════════${RESET}"
printf "  %-26s %s\n" "Web UI:"     "${CYAN}http://localhost:8000${RESET}  (admin / ${SPLUNK_PASS})"
printf "  %-26s %s\n" "HEC endpoint:"  "http://localhost:8088/services/collector"
printf "  %-26s %s\n" "HEC token:"  "${HEC_TOKEN}"
printf "  %-26s %s\n" "REST API:"   "https://localhost:8089"
printf "  %-26s %s\n" "Index:"      "${INDEX_NAME}"
echo ""
echo -e "${YELLOW}Next steps:${RESET}"
echo "  1. Start ngrok for HEC:   ngrok http 8088"
echo "  2. Copy ngrok HTTPS URL → terraform.tfvars as splunk_hec_endpoint"
echo "  3. Copy token above      → terraform.tfvars as splunk_hec_token (or TF_VAR)"
echo "  4. Run: terraform apply"
echo "  5. Import splunk/devsecops_dashboard.xml via Splunk UI:"
echo "     Settings → User Interface → Views → Import"
echo -e "${BOLD}═════════════════════════════════════════════════════════════════${RESET}"
