#!/usr/bin/env bash
# tests/test_score.sh
# Tests for the "score" question type (ordinal / expected level).
#
# Usage: bash tests/test_score.sh [BASE_URL]
# Default BASE_URL: http://localhost:8000
#
# Requires: curl, jq

set -euo pipefail

BASE_URL="${1:-http://localhost:8000}"
PASS=0
FAIL=0

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}FAIL${NC} $1"; FAIL=$((FAIL + 1)); }
info() { echo -e "${YELLOW}----${NC} $1"; }

echo "========================================================"
echo "  laya-serve  |  score question type tests"
echo "  Server: $BASE_URL"
echo "========================================================"

call_predict() {
  local payload="$1"
  local response http_code body

  response=$(curl -s -w "\n%{http_code}" \
    -X POST "${BASE_URL}/predict" \
    -H "Content-Type: application/json" \
    -d "$payload")

  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -n -1)

  if [[ "$http_code" != "200" ]]; then
    echo "  HTTP $http_code  body: $body"
    return 1
  fi
  echo "$body"
}

# -----------------------------------------------------------------------
# Test 1: Urgent / blocking message should score > 1.5 on a 3-level rubric
#         0 = not urgent  |  1 = soon  |  2 = critical / blocking
# -----------------------------------------------------------------------
info "Test 1: critical / blocking issue -> score > 1.5"

PAYLOAD=$(cat <<'EOF'
{
  "state": "Our production API is completely down and every customer is affected. This must be fixed now.",
  "questions": {
    "urgency": {
      "type": "score",
      "instructions": "How urgent is this request?",
      "criteria": ["not urgent", "needs attention soon", "critical deadline or blocking issue"]
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 1 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  SCORE=$(echo "$BODY" | jq -r '.answers.urgency.score // empty')
  TYPE=$(echo "$BODY"  | jq -r '.answers.urgency.type  // empty')
  CONF=$(echo "$BODY"  | jq -r '.answers.urgency.confidence // empty')

  echo "         score (expected level) = $SCORE"
  echo "         confidence             = $CONF"

  if [[ "$TYPE" == "score" ]]; then
    pass "Test 1 – response type is 'score'"
  else
    fail "Test 1 – expected type 'score', got '$TYPE'"
  fi

  if [[ -n "$SCORE" ]]; then
    if awk "BEGIN { exit ($SCORE > 1.5) ? 0 : 1 }"; then
      pass "Test 1 – score > 1.5 (high urgency correctly detected)"
    else
      fail "Test 1 – score = $SCORE, expected > 1.5 for critical/blocking text"
    fi
  else
    fail "Test 1 – no 'score' field in response"
  fi
fi

# -----------------------------------------------------------------------
# Test 2: Routine / non-urgent message should score < 0.8
# -----------------------------------------------------------------------
info "Test 2: non-urgent request -> score < 0.8"

PAYLOAD=$(cat <<'EOF'
{
  "state": "Could you update the documentation link on the help page when you get a chance? No rush.",
  "questions": {
    "urgency": {
      "type": "score",
      "instructions": "How urgent is this request?",
      "criteria": ["not urgent", "needs attention soon", "critical deadline or blocking issue"]
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 2 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  SCORE=$(echo "$BODY" | jq -r '.answers.urgency.score // empty')

  echo "         score (expected level) = $SCORE"

  if [[ -n "$SCORE" ]]; then
    if awk "BEGIN { exit ($SCORE < 0.8) ? 0 : 1 }"; then
      pass "Test 2 – score < 0.8 (low urgency correctly detected)"
    else
      fail "Test 2 – score = $SCORE, expected < 0.8 for non-urgent request"
    fi
  else
    fail "Test 2 – no 'score' field in response"
  fi
fi

# -----------------------------------------------------------------------
# Test 3: Legend field must match criteria labels
# -----------------------------------------------------------------------
info "Test 3: legend field must match supplied criteria"

PAYLOAD=$(cat <<'EOF'
{
  "state": "The export feature is broken for me.",
  "questions": {
    "urgency": {
      "type": "score",
      "instructions": "How urgent is this request?",
      "criteria": ["low", "medium", "high"]
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 3 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  LEGEND_0=$(echo "$BODY" | jq -r '.answers.urgency.legend["0"] // empty')
  LEGEND_1=$(echo "$BODY" | jq -r '.answers.urgency.legend["1"] // empty')
  LEGEND_2=$(echo "$BODY" | jq -r '.answers.urgency.legend["2"] // empty')

  echo "         legend[0] = $LEGEND_0"
  echo "         legend[1] = $LEGEND_1"
  echo "         legend[2] = $LEGEND_2"

  if [[ "$LEGEND_0" == "low" && "$LEGEND_1" == "medium" && "$LEGEND_2" == "high" ]]; then
    pass "Test 3 – legend matches supplied criteria"
  else
    fail "Test 3 – legend mismatch (expected low/medium/high)"
  fi
fi

# -----------------------------------------------------------------------
# Test 4: Score value is within [0, max_level]
# -----------------------------------------------------------------------
info "Test 4: score is in valid range [0, n_levels - 1]"

PAYLOAD=$(cat <<'EOF'
{
  "state": "I am very happy with the service, great job!",
  "questions": {
    "frustration": {
      "type": "score",
      "instructions": "How frustrated does the user sound?",
      "criteria": ["not at all frustrated", "mildly frustrated", "moderately frustrated", "very frustrated"]
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 4 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  SCORE=$(echo "$BODY" | jq -r '.answers.frustration.score // empty')
  N_LEVELS=$(echo "$BODY" | jq '[.answers.frustration.probabilities | keys[]] | length')
  MAX_LEVEL=$((N_LEVELS - 1))

  echo "         score    = $SCORE"
  echo "         n_levels = $N_LEVELS  (max valid = $MAX_LEVEL)"

  if awk "BEGIN { exit (($SCORE >= 0) && ($SCORE <= $MAX_LEVEL)) ? 0 : 1 }"; then
    pass "Test 4 – score in [0, $MAX_LEVEL]"
  else
    fail "Test 4 – score $SCORE out of range [0, $MAX_LEVEL]"
  fi

  # Happy message should be low frustration
  if awk "BEGIN { exit ($SCORE < 1.5) ? 0 : 1 }"; then
    pass "Test 4 – low frustration score for happy message"
  else
    fail "Test 4 – score = $SCORE, expected < 1.5 for happy message"
  fi
fi

# -----------------------------------------------------------------------
# Test 5: JSON object state with a score question
# -----------------------------------------------------------------------
info "Test 5: JSON object state with score question"

PAYLOAD=$(cat <<'EOF'
{
  "state": {
    "ticket_id": "TKT-9901",
    "subject": "Cannot access my account",
    "body": "I have been locked out for 3 days and missed two important deadlines because of this."
  },
  "questions": {
    "severity": {
      "type": "score",
      "instructions": "How severe is the impact of this issue on the user?",
      "criteria": ["minor inconvenience", "moderate impact", "major business impact"]
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 5 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  SCORE=$(echo "$BODY" | jq -r '.answers.severity.score // empty')
  LATENCY=$(echo "$BODY" | jq -r '.latency_ms // "n/a"')

  echo "         score   = $SCORE"
  echo "         latency = ${LATENCY}ms"

  if [[ -n "$SCORE" ]]; then
    if awk "BEGIN { exit ($SCORE > 1.0) ? 0 : 1 }"; then
      pass "Test 5 – score > 1.0 (3-day lockout is at least moderate)"
    else
      fail "Test 5 – score = $SCORE, expected > 1.0 for 3-day lockout"
    fi
  else
    fail "Test 5 – no 'score' field in response"
  fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "========================================================"
echo "  score tests:  PASS=$PASS  FAIL=$FAIL"
echo "========================================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
