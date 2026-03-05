#!/usr/bin/env bash
# Test suite for lib/manifest.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$REPO_ROOT/tests/fixtures/sample-manifest.yml"
PARSER="$REPO_ROOT/lib/manifest.py"

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

assert_json_field() {
    local test_name="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('$field',''))")
    assert_eq "$test_name" "$expected" "$actual"
}

assert_json_length() {
    local test_name="$1" json="$2" expected="$3"
    local actual
    actual=$(echo "$json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    assert_eq "$test_name" "$expected" "$actual"
}

echo "=== Manifest Parser Tests ==="
echo ""

# Test 1: project command returns correct project name
echo "Test 1: project command"
result=$(python3 "$PARSER" "$MANIFEST" project)
assert_json_field "project name" "$result" "project" "td-postman"
assert_json_field "default_provider" "$result" "default_provider" "azure"

# Test 2: envs command returns environment list
echo "Test 2: envs command"
result=$(python3 "$PARSER" "$MANIFEST" envs)
assert_json_length "environment count" "$result" "1"
first_env=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)[0])")
assert_eq "first environment" "sit" "$first_env"

# Test 3: secrets sit returns all 3 secret definitions
echo "Test 3: secrets sit"
result=$(python3 "$PARSER" "$MANIFEST" secrets sit)
assert_json_length "secret count" "$result" "3"
first_name=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('name',''))")
assert_eq "first secret name" "client_secret_td" "$first_name"
second_source=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)[1].get('source',''))")
assert_eq "second secret source" "apim-subscription" "$second_source"
third_secret_flag=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)[2].get('secret',''))")
assert_eq "third secret flag is false" "False" "$third_secret_flag"

# Test 4: outputs sit returns 2 output definitions
echo "Test 4: outputs sit"
result=$(python3 "$PARSER" "$MANIFEST" outputs sit)
assert_json_length "output count" "$result" "2"
first_format=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)[0].get('format',''))")
assert_eq "first output format" "postman" "$first_format"
second_format=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)[1].get('format',''))")
assert_eq "second output format" "dotenv" "$second_format"

# Test 5: azure-config sit returns subscription
echo "Test 5: azure-config sit"
result=$(python3 "$PARSER" "$MANIFEST" azure-config sit)
assert_json_field "subscription" "$result" "subscription" "INZ_TDS_SIT"

# Test 6: nonexistent environment returns exit 1
echo "Test 6: nonexistent environment"
assert_exit_code "secrets nonexistent env" 1 python3 "$PARSER" "$MANIFEST" secrets nonexistent
assert_exit_code "outputs nonexistent env" 1 python3 "$PARSER" "$MANIFEST" outputs nonexistent
assert_exit_code "azure-config nonexistent env" 1 python3 "$PARSER" "$MANIFEST" azure-config nonexistent

# Test 7: invalid file returns exit 1
echo "Test 7: invalid file"
assert_exit_code "nonexistent file" 1 python3 "$PARSER" "/tmp/no-such-file.yml" project

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
