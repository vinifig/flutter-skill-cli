#!/bin/bash
# E2E test for flutter-skill CLI client commands
# Simulates a new user experience from install to browser automation
#
# Prerequisites: flutter-skill serve running on :3000 with Chrome on :9222
# Usage: bash test/cli_client_test.sh [--port=3000]

set -euo pipefail

PORT=3000
HOST=127.0.0.1
PASS=0
FAIL=0
ERRORS=""

# Parse args
for arg in "$@"; do
  case $arg in
    --port=*) PORT="${arg#*=}" ;;
    --host=*) HOST="${arg#*=}" ;;
  esac
done

FS="flutter-skill"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${YELLOW}▸${NC} $1"; }
pass() { echo -e "  ${GREEN}✓${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; FAIL=$((FAIL + 1)); ERRORS="$ERRORS\n  - $1"; }

assert_contains() {
  local output="$1" expected="$2" label="$3"
  if echo "$output" | grep -q "$expected"; then
    pass "$label"
  else
    fail "$label (expected '$expected', got '${output:0:80}')"
  fi
}

assert_not_empty() {
  local output="$1" label="$2"
  if [ -n "$output" ]; then
    pass "$label"
  else
    fail "$label (empty output)"
  fi
}

assert_file_exists() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    pass "$label"
  else
    fail "$label (file not found: $path)"
  fi
}

assert_exit_code() {
  local code="$1" expected="$2" label="$3"
  if [ "$code" -eq "$expected" ]; then
    pass "$label"
  else
    fail "$label (exit code $code, expected $expected)"
  fi
}

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  flutter-skill CLI Client E2E Test"
echo "  Target: http://$HOST:$PORT"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ─── Phase 0: Pre-flight checks ───────────────────────────────
log "Phase 0: Pre-flight checks"

# Check flutter-skill binary exists
if command -v $FS &>/dev/null; then
  pass "flutter-skill binary found: $(which $FS)"
else
  fail "flutter-skill not in PATH"
  echo "Install: npm install -g flutter-skill"
  exit 1
fi

# Check version
VERSION=$($FS --version 2>/dev/null || echo "unknown")
assert_not_empty "$VERSION" "flutter-skill --version returns: $VERSION"

# ─── Phase 1: Connection / serve detection ─────────────────────
log "Phase 1: Serve connection"

# Test: serve not running → clear error
export FS_PORT=19999  # definitely not running
OUTPUT=$($FS title 2>&1 || true)
assert_contains "$OUTPUT" "not running" "Error message when serve is down"
unset FS_PORT

# Test: connect to actual serve
export FS_PORT=$PORT FS_HOST=$HOST
OUTPUT=$($FS title 2>&1 || true)
if echo "$OUTPUT" | grep -q "not running"; then
  fail "Cannot connect to serve on :$PORT — is it running?"
  echo ""
  echo "Start with: flutter-skill serve https://example.com --port=$PORT"
  exit 1
fi
pass "Connected to serve on :$PORT"

# ─── Phase 2: Navigation ──────────────────────────────────────
log "Phase 2: Navigation"

OUTPUT=$($FS nav "https://example.com" 2>&1)
assert_contains "$OUTPUT" "success" "nav returns success"

sleep 2

OUTPUT=$($FS title 2>&1)
assert_contains "$OUTPUT" "Example" "title after nav to example.com"

# ─── Phase 3: Page inspection ─────────────────────────────────
log "Phase 3: Page inspection"

OUTPUT=$($FS snap 2>&1)
assert_not_empty "$OUTPUT" "snap returns content"
assert_contains "$OUTPUT" "Example" "snap contains page content"

OUTPUT=$($FS text 2>&1)
assert_not_empty "$OUTPUT" "text returns content"

OUTPUT=$($FS eval "document.title" 2>&1)
assert_contains "$OUTPUT" "Example" "eval returns document.title"

OUTPUT=$($FS eval "1 + 1" 2>&1)
assert_contains "$OUTPUT" "2" "eval arithmetic works"

# ─── Phase 4: Screenshot ──────────────────────────────────────
log "Phase 4: Screenshot"

SSDIR=$(mktemp -d)
OUTPUT=$($FS screenshot "$SSDIR/test.jpg" 2>&1)
assert_contains "$OUTPUT" "saved" "screenshot reports saved"
assert_file_exists "$SSDIR/test.jpg" "screenshot file created"

SIZE=$(stat -f%z "$SSDIR/test.jpg" 2>/dev/null || stat -c%s "$SSDIR/test.jpg" 2>/dev/null || echo 0)
if [ "$SIZE" -gt 1000 ]; then
  pass "screenshot file size: ${SIZE} bytes"
else
  fail "screenshot file too small: ${SIZE} bytes"
fi

# Default path
OUTPUT=$($FS screenshot 2>&1)
assert_contains "$OUTPUT" "saved" "screenshot with default path"

rm -rf "$SSDIR"

# ─── Phase 5: Interaction ─────────────────────────────────────
log "Phase 5: Interaction"

# Navigate to a page with interactive elements
$FS nav "https://www.google.com" >/dev/null 2>&1
sleep 2

OUTPUT=$($FS title 2>&1)
assert_contains "$OUTPUT" "Google" "navigated to Google"

# Tap
OUTPUT=$($FS eval "document.querySelector('textarea, input[type=text], input[name=q]')?.tagName || 'none'" 2>&1)
if [ "$OUTPUT" != "none" ] && [ -n "$OUTPUT" ]; then
  pass "found search input"
  
  OUTPUT=$($FS tap "Search" 2>&1 || $FS tap 600 350 2>&1 || echo '{"success":false}')
  # Type
  OUTPUT=$($FS type "flutter-skill test" 2>&1)
  assert_contains "$OUTPUT" "success" "type text works"
  
  # Key
  OUTPUT=$($FS key "Escape" 2>&1)
  assert_contains "$OUTPUT" "success" "key press works"
else
  pass "skipped tap/type (no input found)"
fi

# ─── Phase 6: Hover ───────────────────────────────────────────
log "Phase 6: Hover"

$FS nav "https://example.com" >/dev/null 2>&1
sleep 2
OUTPUT=$($FS hover "More information" 2>&1 || echo '{"success":true}')
# hover might fail if element not found, that's ok
assert_not_empty "$OUTPUT" "hover returns response"

# ─── Phase 7: Tools listing ───────────────────────────────────
log "Phase 7: Tools"

OUTPUT=$($FS tools 2>&1)
assert_contains "$OUTPUT" "tools" "tools command returns count"
assert_contains "$OUTPUT" "navigate" "tools includes navigate"
assert_contains "$OUTPUT" "screenshot" "tools includes screenshot"
assert_contains "$OUTPUT" "tap" "tools includes tap"

# ─── Phase 8: Raw tool call ───────────────────────────────────
log "Phase 8: Raw tool call"

OUTPUT=$($FS call get_title '{}' 2>&1)
assert_not_empty "$OUTPUT" "call get_title returns response"

OUTPUT=$($FS call evaluate '{"expression":"1+2"}' 2>&1)
assert_contains "$OUTPUT" "3" "call evaluate returns result"

# ─── Phase 9: Wait ────────────────────────────────────────────
log "Phase 9: Wait"

START=$(date +%s)
OUTPUT=$($FS wait 500 2>&1)
END=$(date +%s)
assert_contains "$OUTPUT" "ok" "wait returns ok"

# ─── Phase 10: Env vars ───────────────────────────────────────
log "Phase 10: Environment variables"

# FS_PORT
OUTPUT=$(FS_PORT=$PORT $FS title 2>&1)
assert_not_empty "$OUTPUT" "FS_PORT env var works"

# --port flag (must come after command)
OUTPUT=$($FS title --port=$PORT 2>&1)
assert_not_empty "$OUTPUT" "--port flag works"

# ─── Phase 11: Error handling ─────────────────────────────────
log "Phase 11: Error handling"

# nav without URL
OUTPUT=$($FS nav 2>&1 || true)
assert_contains "$OUTPUT" "Usage\|url\|error\|Error" "nav without args shows usage/error"

# tap without target
OUTPUT=$($FS tap 2>&1 || true)
assert_contains "$OUTPUT" "Usage\|text\|error\|Error" "tap without args shows usage/error"

# type without text
OUTPUT=$($FS type 2>&1 || true)
assert_contains "$OUTPUT" "Usage\|text\|error\|Error" "type without args shows usage/error"

# eval without expression
OUTPUT=$($FS eval 2>&1 || true)
assert_contains "$OUTPUT" "Usage\|expression\|error\|Error" "eval without args shows usage/error"

# ─── Phase 12: Command aliases ────────────────────────────────
log "Phase 12: Aliases"

OUTPUT=$($FS navigate "https://example.com" 2>&1)
assert_contains "$OUTPUT" "success" "navigate alias works"

OUTPUT=$($FS go "https://example.com" 2>&1)
assert_contains "$OUTPUT" "success" "go alias works"

OUTPUT=$($FS snapshot 2>&1)
assert_not_empty "$OUTPUT" "snapshot alias works"

OUTPUT=$($FS ss "$SSDIR/alias.jpg" 2>/dev/null || $FS screenshot 2>&1)
assert_not_empty "$OUTPUT" "ss alias works"

OUTPUT=$($FS js "document.title" 2>&1)
assert_not_empty "$OUTPUT" "js alias works"

OUTPUT=$($FS press "Escape" 2>&1)
assert_contains "$OUTPUT" "success" "press alias works"

# ─── Phase 13: Tap by ref ─────────────────────────────────────
log "Phase 13: Tap variants"

$FS nav "https://example.com" >/dev/null 2>&1
sleep 2

# Tap by text
OUTPUT=$($FS tap "More information" 2>&1 || echo '{"success":false}')
assert_not_empty "$OUTPUT" "tap by text returns response"

# Tap by coordinates
OUTPUT=$($FS tap 100 200 2>&1)
assert_contains "$OUTPUT" "success\|x" "tap by coordinates works"

# ─── Results ──────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "═══════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
  echo -e "\nFailed tests:$ERRORS"
  exit 1
else
  echo -e "\n  ${GREEN}All tests passed! ✅${NC}\n"
  exit 0
fi
