#!/usr/bin/env bash
#
# Smoke test for CS 454/554 Project 1.
#
# Usage:
#   ./test/smoke.sh                    # defaults to http://localhost:8080 (Compose)
#   BASE_URL=http://localhost:3000 ./test/smoke.sh   # against `npm start`
#
# Start the service first, either via Compose (`docker compose up -d --build`)
# or directly (`npm start`, which needs a reachable Redis).
#
# Every check asserts both the status code and the exact JSON body, and the
# counter checks prove that valid conversions increment /stats while invalid
# ones do not.

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

failures=0
FORMULA='"formula":"kg = lbs * 0.45359237"'

# request <path> -> sets $status and $body
request() {
  local raw
  raw="$(curl -sS -w '\n%{http_code}' "${BASE_URL}$1")"
  status="$(printf '%s' "$raw" | tail -n1)"
  body="$(printf '%s' "$raw" | sed '$d')"
}

# check <expected-status> <path> [expected-body]
check() {
  local expected="$1" path="$2" want_body="${3:-}"

  request "$path"

  if [[ "$status" != "$expected" ]]; then
    printf 'FAIL %-24s got %s, want %s  %s\n' "$path" "$status" "$expected" "$body"
    failures=$((failures + 1))
  elif [[ -n "$want_body" && "$body" != "$want_body" ]]; then
    printf 'FAIL %-24s %s  body %s, want %s\n' "$path" "$status" "$body" "$want_body"
    failures=$((failures + 1))
  else
    printf 'ok   %-24s %s  %s\n' "$path" "$status" "$body"
  fi
}

# Reads the current value of /stats into $count.
read_count() {
  request /stats
  if [[ "$status" != 200 || ! "$body" =~ ^\{\"conversions\":([0-9]+)\}$ ]]; then
    printf 'FAIL %-24s got %s  %s\n' /stats "$status" "$body"
    exit 1
  fi
  count="${BASH_REMATCH[1]}"
}

# check_count <label> <expected>
check_count() {
  read_count
  if [[ "$count" == "$2" ]]; then
    printf 'ok   %-24s %s  %s\n' "/stats ($1)" "$status" "$body"
  else
    printf 'FAIL %-24s conversions=%s, want %s\n' "/stats ($1)" "$count" "$2"
    failures=$((failures + 1))
  fi
}

echo "Smoke testing ${BASE_URL}"

check 200 "/health" '{"status":"ok"}'
check 200 "/"

read_count
before="$count"
printf 'info %-24s conversions=%s at start\n' "/stats" "$before"

# Successful conversions: each must increment the counter.
check 200 "/convert?lbs=0"   "{\"lbs\":0,\"kg\":0,${FORMULA}}"
check 200 "/convert?lbs=150" "{\"lbs\":150,\"kg\":68.039,${FORMULA}}"
check 200 "/convert?lbs=0.1" "{\"lbs\":0.1,\"kg\":0.045,${FORMULA}}"
check_count "after 3 valid" $((before + 3))

# Invalid conversions: each must be rejected and must NOT increment the counter.
check 400 "/convert"          '{"error":"Query parameter lbs is required and must be a number."}'
check 400 "/convert?lbs=abc"  '{"error":"Query parameter lbs is required and must be a number."}'
check 400 "/convert?lbs="     '{"error":"Query parameter lbs is required and must be a number."}'
check 422 "/convert?lbs=-5"   '{"error":"lbs must be a non-negative, finite number."}'
check 422 "/convert?lbs=Infinity" '{"error":"lbs must be a non-negative, finite number."}'
check_count "after invalid" $((before + 3))

check 404 "/no-such-path" '{"error":"Not Found"}'

if (( failures > 0 )); then
  echo "${failures} check(s) failed."
  exit 1
fi

echo "All checks passed."
