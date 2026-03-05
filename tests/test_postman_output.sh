#!/usr/bin/env bash
# Test suite for outputs/postman.sh and outputs/postman_template.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/outputs/postman.sh"

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

echo "=== Postman Output Tests ==="
echo ""

# Test 1: postman_template.py generates correct JSON from stdin
echo "Test 1: template generates correct JSON"
input_json='{"project":"td-postman","environment":"sit","secrets":[{"name":"client_secret_td","value":"test-secret-value","secret":true},{"name":"baseurl","value":"https://example.com","secret":false}]}'
result=$(echo "$input_json" | python3 "$REPO_ROOT/outputs/postman_template.py")
expected=$(python3 -c "import json; print(json.dumps(json.load(open('$REPO_ROOT/tests/fixtures/expected-postman.json')), indent=2))")
assert_eq "template output matches expected" "$expected" "$result"

# Test 2: template output has correct id
echo "Test 2: template output fields"
id_val=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
assert_eq "id field" "td-postman-sit" "$id_val"
name_val=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")
assert_eq "name field uppercase" "SIT" "$name_val"
scope_val=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['_postman_variable_scope'])")
assert_eq "scope field" "environment" "$scope_val"

# Test 3: secret type mapping
echo "Test 3: type mapping"
type1=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['values'][0]['type'])")
assert_eq "secret type" "secret" "$type1"
type2=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['values'][1]['type'])")
assert_eq "default type" "default" "$type2"

# Test 4: enabled field is always true
echo "Test 4: enabled field"
enabled1=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['values'][0]['enabled'])")
assert_eq "enabled is True" "True" "$enabled1"

# Test 5: output_postman_generate writes file
echo "Test 5: output_postman_generate writes file"
outfile="$TMPDIR_TEST/envs/TEST.postman_environment.json"
secrets_json='[{"name":"my_key","value":"my_val","secret":true}]'
output_postman_generate "test-project" "dev" "$outfile" "$secrets_json"
assert_eq "output file exists" "true" "$([ -f "$outfile" ] && echo true || echo false)"
key_val=$(python3 -c "import json; d=json.load(open('$outfile')); print(d['values'][0]['key'])")
assert_eq "written key" "my_key" "$key_val"
val_val=$(python3 -c "import json; d=json.load(open('$outfile')); print(d['values'][0]['value'])")
assert_eq "written value" "my_val" "$val_val"

# Test 6: input validation
echo "Test 6: input validation"
assert_exit_code "empty project" 1 output_postman_generate "" "sit" "$outfile" "$secrets_json"
assert_exit_code "empty environment" 1 output_postman_generate "proj" "" "$outfile" "$secrets_json"
assert_exit_code "empty output_file" 1 output_postman_generate "proj" "sit" "" "$secrets_json"
assert_exit_code "empty secrets_json" 1 output_postman_generate "proj" "sit" "$outfile" ""

# Test 7: invalid JSON to template returns exit 1
echo "Test 7: invalid JSON to template"
assert_exit_code "invalid JSON" 1 bash -c 'echo "not json" | python3 '"$REPO_ROOT"'/outputs/postman_template.py'

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
