#!/usr/bin/env bash
# Test suite for secrets-bridge.sh CLI
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/secrets-bridge.sh"
MANIFEST="$REPO_ROOT/tests/fixtures/sample-manifest.yml"

PASS=0
FAIL=0

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected to contain: $needle"
        echo "    actual output: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local test_name="$1" expected_code="$2"
    shift 2
    local actual_code=0
    "$@" >/dev/null 2>&1 || actual_code=$?
    if [[ "$expected_code" == "$actual_code" ]]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected exit code: $expected_code"
        echo "    actual exit code:   $actual_code"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== CLI Tests ==="
echo ""

# Test 1: --version prints version
echo "Test 1: --version"
result=$(bash "$CLI" --version 2>&1)
assert_contains "version string" "secrets-bridge v1.0.0" "$result"

# Test 2: --help prints usage
echo "Test 2: --help"
result=$(bash "$CLI" --help 2>&1)
assert_contains "help shows usage" "Usage:" "$result"
assert_contains "help shows commands" "validate" "$result"
assert_contains "help shows plan" "plan" "$result"
assert_contains "help shows fetch" "fetch" "$result"
assert_contains "help shows sync" "sync" "$result"

# Test 3: no args prints usage
echo "Test 3: no args"
result=$(bash "$CLI" 2>&1)
assert_contains "no args shows usage" "Usage:" "$result"

# Test 4: validate with valid fixture manifest
echo "Test 4: validate with fixture manifest"
result=$(bash "$CLI" --manifest "$MANIFEST" validate 2>&1)
assert_contains "validate shows project" "td-postman" "$result"
assert_contains "validate shows provider" "azure" "$result"
assert_contains "validate shows valid" "Manifest is valid" "$result"
assert_contains "validate shows env" "sit:" "$result"

# Test 5: validate with no manifest file
echo "Test 5: validate with no manifest"
# Run from /tmp where no manifest exists
actual_code=0
(cd /tmp && bash "$CLI" validate) >/dev/null 2>&1 || actual_code=$?
assert_eq "no manifest exits 1" "1" "$actual_code"

# Test 6: plan with fixture manifest (mock az check by just testing output format)
echo "Test 6: plan sit with fixture"
result=$(bash "$CLI" --manifest "$MANIFEST" plan sit 2>&1)
assert_contains "plan shows project" "td-postman" "$result"
assert_contains "plan shows env" "sit" "$result"
assert_contains "plan shows NAME header" "NAME" "$result"
assert_contains "plan shows SOURCE header" "SOURCE" "$result"
assert_contains "plan shows keyvault secret" "client_secret_td" "$result"
assert_contains "plan shows static" "baseurl" "$result"

# Test 7: unknown command returns exit 1
echo "Test 7: unknown command"
assert_exit_code "unknown command exits 1" 1 bash "$CLI" --manifest "$MANIFEST" notacommand

# Test 8: --manifest with nonexistent file
echo "Test 8: --manifest with bad path"
assert_exit_code "bad manifest path" 1 bash "$CLI" --manifest "/tmp/nonexistent-manifest.yml" validate

# Test 9: plan without env arg
echo "Test 9: plan without env"
assert_exit_code "plan no env" 1 bash "$CLI" --manifest "$MANIFEST" plan

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
