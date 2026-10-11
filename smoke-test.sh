#!/usr/bin/env bash
#
# smoke-test.sh — standalone smoke test for the AMCP platform.
#
# Exercises the inference service, the four "flagship" domain services, and
# the aggregation gateway over plain HTTP with curl. No test framework or
# language runtime dependency beyond bash + curl.
#
# Usage:
#   ./smoke-test.sh
#
# It is tolerant of pieces of the stack not being up yet: a connection
# failure is reported as SKIPPED (informational), while a service that
# responds with a wrong status code or malformed body is reported as FAILED
# (a real problem). Exit code is non-zero iff there is at least one FAILED
# check.

set -u

INFERENCE_URL="${INFERENCE_URL:-http://localhost:8000}"
GATEWAY_URL="${GATEWAY_URL:-http://localhost:8080}"

THREAT_URL="${THREAT_URL:-http://localhost:8001}"
PHISHING_URL="${PHISHING_URL:-http://localhost:8003}"
FRAUD_URL="${FRAUD_URL:-http://localhost:8011}"
PROCESS_URL="${PROCESS_URL:-http://localhost:8021}"

# Gateway endpoints need a Supabase access token when AUTH_DISABLED=0. Pass one with
#   TOKEN=<access_token> ./smoke-test.sh
AUTH_ARGS=()
[ -n "${TOKEN:-}" ] && AUTH_ARGS=(-H "Authorization: Bearer $TOKEN")

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

RESULTS=()

# Colors (disabled if not a tty)
if [ -t 1 ]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; NC=''
fi

record_pass() {
  RESULTS+=("${GREEN}PASS${NC}    $1")
  PASS_COUNT=$((PASS_COUNT + 1))
}

record_fail() {
  RESULTS+=("${RED}FAILED${NC}  $1 -- $2")
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

record_skip() {
  RESULTS+=("${YELLOW}SKIPPED${NC} $1 -- $2")
  SKIP_COUNT=$((SKIP_COUNT + 1))
}

# curl wrapper: does a request and separates "connection refused" style
# failures (curl exit codes 7/28 etc.) from HTTP-level responses.
# Sets globals: HTTP_STATUS, HTTP_BODY, CURL_EXIT
do_request() {
  local method="$1" url="$2" data="${3:-}"
  local tmp
  tmp="$(mktemp)"
  if [ -n "$data" ]; then
    HTTP_STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" --connect-timeout 3 --max-time 10 \
      -X "$method" -H "Content-Type: application/json" "${AUTH_ARGS[@]}" -d "$data" "$url" 2>/tmp/smoke_curl_err.$$)
  else
    HTTP_STATUS=$(curl -sS -o "$tmp" -w "%{http_code}" --connect-timeout 3 --max-time 10 \
      -X "$method" "${AUTH_ARGS[@]}" "$url" 2>/tmp/smoke_curl_err.$$)
  fi
  CURL_EXIT=$?
  HTTP_BODY="$(cat "$tmp")"
  rm -f "$tmp" /tmp/smoke_curl_err.$$
}

is_connection_error() {
  # curl exit codes: 7 = couldn't connect, 28 = timeout, 6 = couldn't resolve host
  case "$CURL_EXIT" in
    7|28|6) return 0 ;;
    *) return 1 ;;
  esac
}

check_health() {
  local name="$1" url="$2"
  do_request GET "$url/health"
  if is_connection_error; then
    record_skip "$name /health" "connection refused/timeout ($url)"
    return 1
  fi
  if [ "$HTTP_STATUS" != "200" ]; then
    record_fail "$name /health" "expected HTTP 200, got $HTTP_STATUS: $HTTP_BODY"
    return 1
  fi
  record_pass "$name /health (200)"
  return 0
}

echo "=============================================="
echo " AMCP platform smoke test"
echo "=============================================="
echo

# ---------------------------------------------------------------------------
# 1. Inference service
# ---------------------------------------------------------------------------
echo "-- Inference service ($INFERENCE_URL) --"

do_request GET "$INFERENCE_URL/health"
if is_connection_error; then
  record_skip "inference /health" "connection refused/timeout ($INFERENCE_URL)"
  INFERENCE_UP=0
else
  INFERENCE_UP=1
  if [ "$HTTP_STATUS" != "200" ]; then
    record_fail "inference /health" "expected HTTP 200, got $HTTP_STATUS: $HTTP_BODY"
  else
    STATUS_FIELD=$(echo "$HTTP_BODY" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([a-z]+)"$/\1/')
    if [ "$STATUS_FIELD" = "ok" ] || [ "$STATUS_FIELD" = "degraded" ]; then
      record_pass "inference /health (200, status=$STATUS_FIELD)"
    else
      record_fail "inference /health" "unexpected status field: '$STATUS_FIELD' (body: $HTTP_BODY)"
    fi
  fi
fi

if [ "$INFERENCE_UP" = "1" ]; then
  do_request GET "$INFERENCE_URL/models"
  if is_connection_error; then
    record_skip "inference /models" "connection refused/timeout ($INFERENCE_URL)"
  elif [ "$HTTP_STATUS" != "200" ]; then
    record_fail "inference /models" "expected HTTP 200, got $HTTP_STATUS: $HTTP_BODY"
  else
    TRIMMED=$(echo "$HTTP_BODY" | tr -d '[:space:]')
    if [[ "$TRIMMED" =~ ^\[.+\]$ ]]; then
      record_pass "inference /models (200, non-empty JSON array)"
    else
      record_fail "inference /models" "expected non-empty JSON array, got: $HTTP_BODY"
    fi
  fi
else
  record_skip "inference /models" "inference service not reachable"
fi

echo

# ---------------------------------------------------------------------------
# 2. Flagship domain services: health + trigger
# ---------------------------------------------------------------------------
echo "-- Flagship domain services --"

# name | base url | sample feature payload
DOMAIN_SERVICES=(
  "threat-detection|$THREAT_URL|{\"features\":{\"packet_rate\":523.4,\"byte_count\":1048576,\"unique_ports\":12,\"failed_logins\":3,\"session_duration\":45.2}}"
  "phishing-detector|$PHISHING_URL|{\"features\":{\"url_length\":87,\"num_subdomains\":4,\"has_ip_address\":1,\"domain_age_days\":2,\"num_special_chars\":9}}"
  "fraud-detector|$FRAUD_URL|{\"features\":{\"transaction_amount\":4823.5,\"account_age_days\":30,\"num_transactions_24h\":18,\"distance_from_home_km\":1200,\"is_foreign_country\":1}}"
  "process-anomaly-detector|$PROCESS_URL|{\"features\":{\"temperature\":92.3,\"vibration\":0.87,\"pressure\":145.2,\"rpm\":3200,\"runtime_hours\":510}}"
)

for entry in "${DOMAIN_SERVICES[@]}"; do
  IFS='|' read -r svc_name svc_url payload <<< "$entry"

  if check_health "$svc_name" "$svc_url"; then
    do_request POST "$svc_url/trigger" "$payload"
    if is_connection_error; then
      record_skip "$svc_name /trigger" "connection refused/timeout ($svc_url)"
    elif [ "$HTTP_STATUS" != "200" ]; then
      record_fail "$svc_name /trigger" "expected HTTP 200, got $HTTP_STATUS: $HTTP_BODY"
    else
      if echo "$HTTP_BODY" | grep -q '"published"[[:space:]]*:[[:space:]]*\(true\|false\)'; then
        PUB=$(echo "$HTTP_BODY" | grep -o '"published"[[:space:]]*:[[:space:]]*[a-z]*' | sed -E 's/.*: *//')
        record_pass "$svc_name /trigger (200, published=$PUB)"
      else
        record_fail "$svc_name /trigger" "expected 'published' boolean field, got: $HTTP_BODY"
      fi
    fi
  else
    record_skip "$svc_name /trigger" "service not reachable, skipping trigger check"
  fi
done

echo

# ---------------------------------------------------------------------------
# 3. Gateway
# ---------------------------------------------------------------------------
echo "-- Gateway ($GATEWAY_URL) --"

if check_health "gateway" "$GATEWAY_URL"; then
  GATEWAY_UP=1
else
  GATEWAY_UP=0
fi

for endpoint in "/models" "/domains/status" "/alerts?limit=10"; do
  label="gateway $endpoint"
  if [ "$GATEWAY_UP" = "1" ]; then
    do_request GET "$GATEWAY_URL$endpoint"
    if is_connection_error; then
      record_skip "$label" "connection refused/timeout"
    elif [ "$HTTP_STATUS" != "200" ]; then
      record_fail "$label" "expected HTTP 200, got $HTTP_STATUS: $HTTP_BODY"
    else
      record_pass "$label (200)"
    fi
  else
    record_skip "$label" "gateway not reachable"
  fi
done

echo

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo " Summary"
for r in "${RESULTS[@]}"; do
  echo -e "$r"
done
echo
echo "Passed: $PASS_COUNT   Failed: $FAIL_COUNT   Skipped: $SKIP_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo -e "${RED}Smoke test FAILED${NC}"
  exit 1
else
  echo -e "${GREEN}Smoke test completed (no hard failures)${NC}"
  exit 0
fi
