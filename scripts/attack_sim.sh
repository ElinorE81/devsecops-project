#!/usr/bin/env bash
# ==============================================================================
#  attack_sim.sh — Layer 7 HTTP Flood Simulation
#  DevSecOps Self-Healing Cloud Project
#
#  Sends concurrent HTTP GET requests to the ALB to:
#    1. Trigger the WAF RateLimitRule  (> var.waf_rate_limit req / 5-min window)
#    2. Spike EC2 CPU                  (each request runs prime calculation)
#    3. Generate rich WAF logs         (visible in Splunk within ~60 seconds)
#
#  Usage:
#    ./attack_sim.sh <ALB_DNS_OR_URL> [OPTIONS]
#
#  Options:
#    --concurrency N   Parallel curl workers          (default: 40)
#    --duration    S   Flood duration in seconds      (default: 120)
#    --path        P   URL path to target             (default: /)
#    -h, --help        Show this help
#
#  Examples:
#    ./attack_sim.sh devsecops-prod-alb-123456.us-east-1.elb.amazonaws.com
#    ./attack_sim.sh http://my-alb.example.com --concurrency 60 --duration 180
#    ./attack_sim.sh http://my-alb.example.com --path /health --duration 60
#
#  Requirements: bash >= 4.0, curl
# ==============================================================================
set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m' YELLOW='\033[1;33m' GREEN='\033[0;32m'
  CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET=''
fi

die()  { echo -e "${RED}ERROR: $*${RESET}" >&2; exit 1; }
info() { echo -e "${CYAN}$*${RESET}"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
CONCURRENCY=40
DURATION=120
TARGET_PATH="/"
TARGET_URL=""
CONNECT_TIMEOUT=5
REQUEST_TIMEOUT=10

# ── Usage ──────────────────────────────────────────────────────────────────────
usage() {
cat <<EOF

${BOLD}Usage:${RESET} $(basename "$0") <ALB_DNS_OR_URL> [--concurrency N] [--duration S] [--path P]

Generates a Layer 7 HTTP flood to trigger WAF rate limiting and spike EC2 CPU.

${BOLD}Arguments:${RESET}
  ALB_DNS_OR_URL    Target ALB DNS name or full URL (http:// prepended if missing)

${BOLD}Options:${RESET}
  --concurrency N   Parallel workers   (default: ${CONCURRENCY})
  --duration S      Run time, seconds  (default: ${DURATION})
  --path P          Request path       (default: ${TARGET_PATH})
  -h, --help        Show this message

${BOLD}Examples:${RESET}
  $(basename "$0") devsecops-prod-alb-123456.us-east-1.elb.amazonaws.com
  $(basename "$0") http://my-alb.example.com --concurrency 60 --duration 180
EOF
  exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && usage

TARGET_URL="$1"; shift
[[ "$TARGET_URL" == "-h" || "$TARGET_URL" == "--help" ]] && usage

# Prepend scheme if bare hostname given
[[ "$TARGET_URL" != http://* && "$TARGET_URL" != https://* ]] \
  && TARGET_URL="http://${TARGET_URL}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --concurrency) CONCURRENCY="$2"; shift 2 ;;
    --duration)    DURATION="$2";    shift 2 ;;
    --path)        TARGET_PATH="$2"; shift 2 ;;
    -h|--help)     usage ;;
    *) die "Unknown option: $1 (run with --help)" ;;
  esac
done

# Sanitise numerics
[[ "$CONCURRENCY" =~ ^[0-9]+$ ]] \
  || die "--concurrency must be a positive integer, got: $CONCURRENCY"
[[ "$DURATION" =~ ^[0-9]+$ ]] \
  || die "--duration must be a positive integer in seconds, got: $DURATION"
(( CONCURRENCY >= 1 && CONCURRENCY <= 500 )) \
  || die "--concurrency must be between 1 and 500"
(( DURATION >= 5 )) \
  || die "--duration must be at least 5 seconds"

FULL_URL="${TARGET_URL%/}${TARGET_PATH}"

# ── Banner ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${RED}${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${RED}${BOLD}║      LAYER 7 HTTP FLOOD — DevSecOps Attack Simulation        ║${RESET}"
echo -e "${RED}${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
printf "  %-14s %s\n" "Target URL:"   "${CYAN}${FULL_URL}${RESET}"
printf "  %-14s %s\n" "Workers:"      "${CONCURRENCY} parallel curl processes"
printf "  %-14s %s\n" "Duration:"     "${DURATION} seconds"
printf "  %-14s %s\n" "WAF trigger:"  ">1000 req / 5-min window from this IP"
echo ""

# ── Pre-flight connectivity check ──────────────────────────────────────────────
echo -n "Pre-flight: checking /health endpoint... "
HEALTH_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout "$CONNECT_TIMEOUT" \
  --max-time "$REQUEST_TIMEOUT" \
  "${TARGET_URL%/}/health" 2>/dev/null) || HEALTH_CODE="000"

case "$HEALTH_CODE" in
  200) echo -e "${GREEN}OK (HTTP 200)${RESET}" ;;
  000) echo -e "${RED}UNREACHABLE${RESET}"
       die "Cannot connect to ${TARGET_URL}. Verify ALB DNS name and that terraform apply has completed." ;;
  *)   echo -e "${YELLOW}HTTP ${HEALTH_CODE} — proceeding anyway${RESET}" ;;
esac

# Display public egress IP so you can correlate in WAF / Splunk logs
echo -n "Pre-flight: resolving outbound IP... "
EGRESS_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null \
  || curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
  || echo "unknown")
echo -e "${CYAN}${EGRESS_IP}${RESET}"
echo ""
echo -e "  ${DIM}All WAF blocks will appear under IP ${EGRESS_IP} in Splunk.${RESET}"
echo ""

# ── Safety gate ────────────────────────────────────────────────────────────────
echo -e "${YELLOW}${BOLD}WARNING: This script generates significant traffic.${RESET}"
echo -e "${YELLOW}Only run against infrastructure you own and are authorised to test.${RESET}"
echo ""
read -r -p "  Type FLOOD to confirm and start the simulation: " CONFIRM
echo ""
[[ "$CONFIRM" == "FLOOD" ]] || { echo "Aborted."; exit 0; }

# ── Temp workspace & cleanup ───────────────────────────────────────────────────
TMP_DIR=$(mktemp -d /tmp/attack_sim.XXXXXX)
RUNNING_FLAG="${TMP_DIR}/running"
touch "$RUNNING_FLAG"

START_EPOCH=$(date +%s)
PREV_TOTAL=0
WAF_ANNOUNCED=false

cleanup() {
  local exit_code=$?
  rm -f "$RUNNING_FLAG"
  wait 2>/dev/null || true   # reap all background workers

  local end_epoch elapsed total ok blocked errors avg_rate pct_blocked
  end_epoch=$(date +%s)
  elapsed=$(( end_epoch - START_EPOCH ))

  # Tally across all per-worker log files
  total=0; ok=0; blocked=0
  for f in "${TMP_DIR}"/w*.log; do
    [[ -f "$f" ]] || continue
    f_total=$(wc -l < "$f" 2>/dev/null || echo 0)
    f_ok=$(grep -c "^200$" "$f" 2>/dev/null || echo 0)
    f_blocked=$(grep -cE "^(403|429)$" "$f" 2>/dev/null || echo 0)
    total=$(( total + f_total ))
    ok=$(( ok + f_ok ))
    blocked=$(( blocked + f_blocked ))
  done
  errors=$(( total - ok - blocked ))
  avg_rate=$(( elapsed > 0 ? total / elapsed : 0 ))
  if (( total > 0 )); then
    pct_blocked=$(( blocked * 100 / total ))
  else
    pct_blocked=0
  fi

  echo ""
  echo ""
  echo -e "${BOLD}══════════════════════════ SUMMARY ══════════════════════════════${RESET}"
  printf "  %-22s %s\n"  "Duration:"           "${elapsed}s"
  printf "  %-22s %s\n"  "Total requests:"     "${total}"
  printf "  %-22s %s\n"  "Average rate:"       "${avg_rate} req/s"
  echo -e "  ${GREEN}$(printf '%-22s %s' '200 OK:' "${ok}")${RESET}"
  if (( blocked > 0 )); then
    echo -e "  ${RED}${BOLD}$(printf '%-22s %s' 'Blocked by WAF (403/429):' "${blocked}  (${pct_blocked}% of traffic)")${RESET}"
  else
    echo -e "  $(printf '%-22s %s' 'Blocked by WAF:' '0  (WAF did not trigger)')"
  fi
  [[ "$errors" -gt 0 ]] \
    && echo -e "  ${YELLOW}$(printf '%-22s %s' 'Curl errors/timeouts:' "${errors}")${RESET}"
  echo -e "${BOLD}═════════════════════════════════════════════════════════════════${RESET}"

  if (( blocked > 0 )); then
    echo ""
    echo -e "  ${RED}${BOLD}WAF triggered.${RESET} Expected next steps:"
    echo -e "  ${DIM}1. CloudWatch alarm fires within ~60 s of the first block${RESET}"
    echo -e "  ${DIM}2. SNS delivers payload to n8n webhook${RESET}"
    echo -e "  ${DIM}3. n8n queries Splunk for attacker context (IP: ${EGRESS_IP})${RESET}"
    echo -e "  ${DIM}4. n8n creates Outline incident report and sends Human-in-the-loop email${RESET}"
    echo ""
    echo -e "  Splunk search to verify:"
    echo -e "  ${CYAN}index=devsecops_security action=BLOCK httpRequest.clientIp=\"${EGRESS_IP}\"${RESET}"
  else
    echo ""
    echo -e "  ${YELLOW}WAF did not trigger. Try increasing --concurrency or --duration.${RESET}"
    echo -e "  ${DIM}Current rate limit: 1000 req / 5-min. You need >3.3 req/s sustained.${RESET}"
  fi
  echo ""

  rm -rf "$TMP_DIR"
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# ── Worker function ────────────────────────────────────────────────────────────
# Each worker runs in its own subshell and appends the HTTP status code to its
# private log file. Private files avoid concurrent-write corruption.
worker() {
  local id="$1"
  local log="${TMP_DIR}/w${id}.log"
  local code

  while [[ -f "$RUNNING_FLAG" ]]; do
    code=$(curl -s -o /dev/null -w "%{http_code}" \
      --connect-timeout "$CONNECT_TIMEOUT" \
      --max-time "$REQUEST_TIMEOUT" \
      -H "User-Agent: DevSecOps-AttackSim/1.0 (authorized-pentest)" \
      -H "Accept: application/json" \
      -H "X-Attack-Sim: devsecops-flood-$(date +%s)" \
      "$FULL_URL" 2>/dev/null) || code="ERR"
    printf '%s\n' "$code" >> "$log"
  done
}

# ── Launch workers ─────────────────────────────────────────────────────────────
echo -e "${RED}${BOLD}[FLOOD STARTED]${RESET} Spawning ${CONCURRENCY} workers → ${FULL_URL}"
echo ""
for i in $(seq 1 "$CONCURRENCY"); do
  worker "$i" &
done

# Brief ramp-up pause so workers establish connections before first stat read
sleep 1

# ── Live stats loop ────────────────────────────────────────────────────────────
printf "  ${BOLD}%-8s  %-9s  %-8s  %-10s  %-14s  %-8s${RESET}\n" \
  "Elapsed" "Total" "Rate/s" "200 OK" "Blocked(WAF)" "Errors"
printf "  %s\n" \
  "──────  ─────────  ────────  ──────────  ──────────────  ────────"

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START_EPOCH ))
  [[ "$ELAPSED" -ge "$DURATION" ]] && break

  # Aggregate from per-worker log files
  total=0; ok=0; blocked=0
  for f in "${TMP_DIR}"/w*.log; do
    [[ -f "$f" ]] || continue
    f_total=$(wc -l < "$f" 2>/dev/null || echo 0)
    f_ok=$(grep -c "^200$" "$f" 2>/dev/null || echo 0)
    f_blocked=$(grep -cE "^(403|429)$" "$f" 2>/dev/null || echo 0)
    total=$(( total + f_total ))
    ok=$(( ok + f_ok ))
    blocked=$(( blocked + f_blocked ))
  done
  errors=$(( total > 0 ? total - ok - blocked : 0 ))
  rate=$(( total - PREV_TOTAL ))
  PREV_TOTAL="$total"

  # Announce WAF trigger once
  if (( blocked > 0 )) && [[ "$WAF_ANNOUNCED" == "false" ]]; then
    WAF_ANNOUNCED=true
    echo ""
    echo -e "  ${RED}${BOLD}▶ WAF RATE LIMIT TRIGGERED — blocked requests detected${RESET}"
    echo -e "  ${YELLOW}  CloudWatch alarm will fire within ~60 s → watch n8n and Splunk${RESET}"
    echo ""
  fi

  # Colour the blocked column red once WAF fires
  BLOCK_FMT="${RESET}"
  (( blocked > 0 )) && BLOCK_FMT="${RED}${BOLD}"

  printf "  %02d:%02d     %8d   %6d   %8d   ${BLOCK_FMT}%12d${RESET}   %6d\n" \
    $(( ELAPSED / 60 )) $(( ELAPSED % 60 )) \
    "$total" "$rate" "$ok" "$blocked" "$errors"

  sleep 1
done

# Signal workers to stop and let cleanup() handle the summary
rm -f "$RUNNING_FLAG"
echo ""
echo -e "${BOLD}[FLOOD ENDED]${RESET} Duration reached. Draining workers..."
