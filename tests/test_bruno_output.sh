#!/usr/bin/env bash
# Test suite for outputs/bruno.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/outputs/bruno.sh"

PASS=0
FAIL=0
TMPDIR_TEST=""

setup() {
    TMPDIR_TEST=$(mktemp -d)
}

teardown() {
    [[ -n "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

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

trap teardown EXIT
setup

echo "=== Bruno Output Tests ==="
echo ""

# Test 1: generates correct .bru format
echo "Test 1: basic .bru generation"
outfile="$TMPDIR_TEST/NZTD-SIT.bru"
secrets_json='[{"name":"client_secret_td","value":"abc123"},{"name":"baseurl","value":"https://example.com"}]'
output_bruno_generate "td-postman" "sit" "$outfile" "$secrets_json"
assert_eq "output file exists" "true" "$([ -f "$outfile" ] && echo true || echo false)"

# Test 2: file starts with vars {
echo "Test 2: file structure"
first_line=$(head -1 "$outfile")
assert_eq "starts with vars {" "vars {" "$first_line"
last_line=$(tail -1 "$outfile")
assert_eq "ends with }" "}" "$last_line"

# Test 3: contains expected key-value pairs
echo "Test 3: key-value pairs"
line2=$(sed -n '2p' "$outfile")
assert_eq "first entry" "  client_secret_td: abc123" "$line2"
line3=$(sed -n '3p' "$outfile")
assert_eq "second entry" "  baseurl: https://example.com" "$line3"

# Test 4: line count (header + N entries + footer)
echo "Test 4: line count"
line_count=$(wc -l < "$outfile" | tr -d ' ')
assert_eq "line count" "4" "$line_count"

# Test 5: input validation
echo "Test 5: input validation"
assert_exit_code "empty project" 1 output_bruno_generate "" "sit" "$outfile" "$secrets_json"
assert_exit_code "empty environment" 1 output_bruno_generate "proj" "" "$outfile" "$secrets_json"
assert_exit_code "empty output_file" 1 output_bruno_generate "proj" "sit" "" "$secrets_json"
assert_exit_code "empty secrets_json" 1 output_bruno_generate "proj" "sit" "$outfile" ""

# Test 6: creates output directory if needed
echo "Test 6: creates output directory"
nested_outfile="$TMPDIR_TEST/nested/dir/test.bru"
output_bruno_generate "test" "dev" "$nested_outfile" "$secrets_json"
assert_eq "nested file exists" "true" "$([ -f "$nested_outfile" ] && echo true || echo false)"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
