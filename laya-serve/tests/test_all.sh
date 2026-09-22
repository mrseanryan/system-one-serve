#!/usr/bin/env bash
# tests/test_all.sh
# Runs the full laya-serve test suite: health, noul, choice, score.
#
# Usage: bash tests/test_all.sh [BASE_URL]
# Default BASE_URL: http://localhost:8000
#
# Requires: curl, jq

set -euo pipefail

BASE_URL="${1:-http://localhost:8000}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'

echo ""
echo -e "${BOLD}========================================================${NC}"
echo -e "${BOLD}  laya-serve full test suite${NC}"
echo -e "${BOLD}  Server: $BASE_URL${NC}"
echo -e "${BOLD}========================================================${NC}"
echo ""

# -----------------------------------------------------------------------
# Prerequisite: server must be reachable
# -----------------------------------------------------------------------
echo -e "${YELLOW}-- Checking server health ...${NC}"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/health" || true)
if [[ "$HTTP_CODE" != "200" ]]; then
  echo -e "${RED}ERROR: server not reachable at ${BASE_URL} (HTTP $HTTP_CODE)${NC}"
  echo "  Start the server first:  python server.py"
  exit 1
fi

HEALTH=$(curl -s "${BASE_URL}/health")
DEVICE=$(echo "$HEALTH"   | jq -r '.device // "unknown"')
LOADED=$(echo "$HEALTH"   | jq -r '.loaded_models | join(", ") // "none"')
echo -e "${GREEN}  Server is up.${NC}  device=$DEVICE  loaded=[$LOADED]"
echo ""

# -----------------------------------------------------------------------
# Prerequisite: jq must be installed
# -----------------------------------------------------------------------
if ! command -v jq &>/dev/null; then
  echo -e "${RED}ERROR: jq is not installed.${NC}"
  echo "  Install it with:  winget install jqlang.jq"
  exit 1
fi

# -----------------------------------------------------------------------
# Run each test file and track pass/fail counts
# -----------------------------------------------------------------------
SUITES=("test_noul.sh" "test_choice.sh" "test_score.sh")
TOTAL_PASS=0
TOTAL_FAIL=0
SUITE_RESULTS=()

for suite in "${SUITES[@]}"; do
  echo ""
  echo -e "${BOLD}Running $suite ...${NC}"
  echo "--------------------------------------------------------"

  set +e
  bash "${SCRIPT_DIR}/${suite}" "$BASE_URL"
  EXIT_CODE=$?

  # Extract pass/fail counts from the last summary line printed by the sub-script
  # The sub-scripts print:  "PASS=N  FAIL=M" (with possible color codes)
  SUITE_RESULTS+=("$suite: exit=$EXIT_CODE")

  if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "${GREEN}  $suite PASSED${NC}"
  else
    echo -e "${RED}  $suite FAILED (exit $EXIT_CODE)${NC}"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
done

# -----------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------
echo ""
echo -e "${BOLD}========================================================"
echo "  Full suite results"
echo -e "========================================================${NC}"

for r in "${SUITE_RESULTS[@]}"; do
  if [[ "$r" == *"exit=0"* ]]; then
    echo -e "  ${GREEN}PASS${NC}  $r"
  else
    echo -e "  ${RED}FAIL${NC}  $r"
  fi
done

echo ""
if [[ $TOTAL_FAIL -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}All suites passed.${NC}"
  exit 0
else
  echo -e "${RED}${BOLD}$TOTAL_FAIL suite(s) failed.${NC}"
  exit 1
fi
