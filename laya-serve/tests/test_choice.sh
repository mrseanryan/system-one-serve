#!/usr/bin/env bash
# tests/test_choice.sh
# Tests for the "choice" question type (classification / routing).
#
# Usage: bash tests/test_choice.sh [BASE_URL]
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
echo "  laya-serve  |  choice question type tests"
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
# Test 1: Billing email routed to 'billing' department
# -----------------------------------------------------------------------
info "Test 1: billing email -> choice == 'billing'"

PAYLOAD=$(cat <<'EOF'
{
  "state": {
    "from": "user@acme.com",
    "subject": "Duplicate charge on invoice #4411",
    "body": "Hi, we were billed twice for March. Please refund the duplicate today."
  },
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which department should handle this request?",
      "criteria": {
        "billing": "invoices, payments, charges, refunds",
        "technical": "bugs, outages, system errors, broken features",
        "sales": "pricing, new contracts, upgrades",
        "other": "everything else"
      }
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 1 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  CHOICE=$(echo "$BODY" | jq -r '.answers.department.choice // empty')
  CONF=$(echo "$BODY"   | jq -r '.answers.department.confidence // empty')
  TYPE=$(echo "$BODY"   | jq -r '.answers.department.type // empty')

  echo "         choice     = $CHOICE"
  echo "         confidence = $CONF"

  if [[ "$TYPE" == "choice" ]]; then
    pass "Test 1 – response type is 'choice'"
  else
    fail "Test 1 – expected type 'choice', got '$TYPE'"
  fi

  if [[ "$CHOICE" == "billing" ]]; then
    pass "Test 1 – department correctly classified as 'billing'"
  else
    fail "Test 1 – expected 'billing', got '$CHOICE'"
  fi
fi

# -----------------------------------------------------------------------
# Test 2: Bug report routed to 'technical'
# -----------------------------------------------------------------------
info "Test 2: bug report -> choice == 'technical'"

PAYLOAD=$(cat <<'EOF'
{
  "state": "The login page throws a 500 error every time I try to sign in from Firefox.",
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which department should handle this request?",
      "criteria": {
        "billing": "invoices, payments, charges, refunds",
        "technical": "bugs, outages, system errors, broken features",
        "sales": "pricing, new contracts, upgrades",
        "other": "everything else"
      }
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 2 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  CHOICE=$(echo "$BODY" | jq -r '.answers.department.choice // empty')
  CONF=$(echo "$BODY"   | jq -r '.answers.department.confidence // empty')

  echo "         choice     = $CHOICE"
  echo "         confidence = $CONF"

  if [[ "$CHOICE" == "technical" ]]; then
    pass "Test 2 – department correctly classified as 'technical'"
  else
    fail "Test 2 – expected 'technical', got '$CHOICE'"
  fi
fi

# -----------------------------------------------------------------------
# Test 3: Probabilities sum to 1.0
# -----------------------------------------------------------------------
info "Test 3: probabilities must sum to ~1.0"

PAYLOAD=$(cat <<'EOF'
{
  "state": "I would like to upgrade my plan to the Enterprise tier.",
  "questions": {
    "department": {
      "type": "choice",
      "instructions": "Which department should handle this request?",
      "criteria": {
        "billing": "invoices, payments, charges, refunds",
        "technical": "bugs, outages, system errors, broken features",
        "sales": "pricing, new contracts, upgrades",
        "other": "everything else"
      }
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 3 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  PROBS_SUM=$(echo "$BODY" | jq '[.answers.department.probabilities | to_entries[].value] | add')
  echo "         probabilities sum = $PROBS_SUM"

  if awk "BEGIN { exit (($PROBS_SUM > 0.99) && ($PROBS_SUM < 1.01)) ? 0 : 1 }"; then
    pass "Test 3 – probabilities sum to ~1.0"
  else
    fail "Test 3 – probabilities sum = $PROBS_SUM, expected ~1.0"
  fi
fi

# -----------------------------------------------------------------------
# Test 4: Boolean criteria (list-style)
# -----------------------------------------------------------------------
info "Test 4: choice with list-style criteria"

PAYLOAD=$(cat <<'EOF'
{
  "state": "The application crashed and I lost all my work.",
  "questions": {
    "sentiment": {
      "type": "choice",
      "instructions": "What is the overall sentiment of this message?",
      "criteria": {
        "positive": "happy, satisfied, grateful",
        "neutral": "informational, neither positive nor negative",
        "negative": "frustrated, angry, disappointed"
      }
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 4 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  CHOICE=$(echo "$BODY" | jq -r '.answers.sentiment.choice // empty')
  CONF=$(echo "$BODY"   | jq -r '.answers.sentiment.confidence // empty')

  echo "         choice     = $CHOICE"
  echo "         confidence = $CONF"

  if [[ "$CHOICE" == "negative" ]]; then
    pass "Test 4 – crash message correctly labelled 'negative'"
  else
    fail "Test 4 – expected 'negative', got '$CHOICE'"
  fi
fi

# -----------------------------------------------------------------------
# Test 5: confidence field is present and in [0, 1]
# -----------------------------------------------------------------------
info "Test 5: confidence field is in range [0, 1]"

PAYLOAD=$(cat <<'EOF'
{
  "state": "How do I reset my password?",
  "questions": {
    "intent": {
      "type": "choice",
      "instructions": "What is the user's intent?",
      "criteria": {
        "support": "help, questions, how-to",
        "complaint": "dissatisfaction, problems, issues",
        "feedback": "suggestions, feature requests"
      }
    }
  }
}
EOF
)

BODY=$(call_predict "$PAYLOAD") || { fail "Test 5 – HTTP error"; }

if [[ -n "$BODY" ]]; then
  CONF=$(echo "$BODY" | jq -r '.answers.intent.confidence // empty')
  echo "         confidence = $CONF"

  if awk "BEGIN { exit (($CONF >= 0.0) && ($CONF <= 1.0)) ? 0 : 1 }"; then
    pass "Test 5 – confidence in [0, 1]"
  else
    fail "Test 5 – confidence = $CONF out of range"
  fi
fi

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
echo ""
echo "========================================================"
echo "  choice tests:  PASS=$PASS  FAIL=$FAIL"
echo "========================================================"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
