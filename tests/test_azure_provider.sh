#!/usr/bin/env bash
# Test suite for providers/azure.sh
# Uses mocked az CLI to avoid real Azure calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$REPO_ROOT/providers/azure.sh"

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

# ---------------------------------------------------------------------------
# Mock az CLI
# ---------------------------------------------------------------------------
az() {
    case "$*" in
        "account show")
            echo '{"id":"mock-sub-id","name":"MockSubscription"}'
            ;;
        "account show --query id -o tsv")
            echo "mock-sub-id"
            ;;
        "account set --subscription MockSubscription")
            return 0
            ;;
        "account set --subscription BadSubscription")
            return 1
            ;;
        *"keyvault secret show"*"--name mock-secret"*)
            echo "mock-kv-value"
            ;;
        *"keyvault secret show"*"--name bad-secret"*)
            return 1
            ;;
        *"rest --method post"*"listSecrets"*)
            echo "mock-apim-key"
            ;;
        *"apim nv show-secret"*)
            echo "mock-named-value"
            ;;
        *)
            echo "UNEXPECTED az call: $*" >&2
            return 1
            ;;
    esac
}
export -f az

echo "=== Azure Provider Tests ==="
echo ""

# Test 1: provider_azure_check succeeds with mock
echo "Test 1: azure check"
assert_exit_code "az check succeeds" 0 provider_azure_check

# Test 2: set subscription
echo "Test 2: set subscription"
assert_exit_code "set valid subscription" 0 provider_azure_set_subscription "MockSubscription"
assert_exit_code "set bad subscription" 1 provider_azure_set_subscription "BadSubscription"

# Test 3: fetch keyvault
echo "Test 3: fetch keyvault"
result=$(provider_azure_fetch_keyvault "my-vault" "mock-secret")
assert_eq "keyvault returns value" "mock-kv-value" "$result"

# Test 4: keyvault input validation
echo "Test 4: keyvault input validation"
assert_exit_code "empty vault" 1 provider_azure_fetch_keyvault "" "mock-secret"
assert_exit_code "empty secret" 1 provider_azure_fetch_keyvault "my-vault" ""

# Test 5: fetch APIM subscription key
echo "Test 5: fetch APIM subscription key"
result=$(provider_azure_fetch_apim_subscription "my-rg" "my-apim" "my-sub")
assert_eq "apim sub returns key" "mock-apim-key" "$result"

# Test 6: APIM subscription input validation
echo "Test 6: APIM subscription input validation"
assert_exit_code "empty rg" 1 provider_azure_fetch_apim_subscription "" "my-apim" "my-sub"
assert_exit_code "empty service" 1 provider_azure_fetch_apim_subscription "my-rg" "" "my-sub"
assert_exit_code "empty sub_id" 1 provider_azure_fetch_apim_subscription "my-rg" "my-apim" ""

# Test 7: fetch APIM named value
echo "Test 7: fetch APIM named value"
result=$(provider_azure_fetch_apim_named_value "my-rg" "my-apim" "my-nv")
assert_eq "apim nv returns value" "mock-named-value" "$result"

# Test 8: APIM named value input validation
echo "Test 8: APIM named value input validation"
assert_exit_code "empty rg" 1 provider_azure_fetch_apim_named_value "" "my-apim" "my-nv"
assert_exit_code "empty service" 1 provider_azure_fetch_apim_named_value "my-rg" "" "my-nv"
assert_exit_code "empty nv_id" 1 provider_azure_fetch_apim_named_value "my-rg" "my-apim" ""

# Test 9: fetch dispatcher
echo "Test 9: fetch dispatcher"
result=$(provider_azure_fetch keyvault "my-vault" "mock-secret")
assert_eq "dispatch keyvault" "mock-kv-value" "$result"
result=$(provider_azure_fetch apim-subscription "my-rg" "my-apim" "my-sub")
assert_eq "dispatch apim-subscription" "mock-apim-key" "$result"
result=$(provider_azure_fetch apim-named-value "my-rg" "my-apim" "my-nv")
assert_eq "dispatch apim-named-value" "mock-named-value" "$result"

# Test 10: unknown source type
echo "Test 10: unknown source type"
assert_exit_code "unknown source" 1 provider_azure_fetch "unknown-source" "arg1" "arg2"

# Test 11: set subscription input validation
echo "Test 11: set subscription empty"
assert_exit_code "empty subscription" 1 provider_azure_set_subscription ""

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
