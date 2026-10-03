#!/usr/bin/env bash
# Test suite for multi-source fetching: wallet, bitwarden, keyvault fallback
# chains and the --source filter. az, bw and secret-tool are mocked, so the
# real OS wallet and cloud accounts are never touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLI="$REPO_ROOT/secrets-bridge.sh"
MANIFEST="$REPO_ROOT/tests/fixtures/sources-manifest.yml"

# The secrets library prefers macOS Keychain / Windows Credential Manager over
# secret-tool, so the mock below would not intercept: skip rather than write
# into a real wallet.
# Mirrors the library's backend detection: pwsh only means Credential Manager on Windows
if [[ "$OSTYPE" == darwin* || "$OSTYPE" == msys* || "$OSTYPE" == cygwin* ]] || command -v powershell.exe &>/dev/null; then
    echo "SKIP: test_sources.sh needs the libsecret backend (Linux) to mock the wallet"
    exit 0
fi

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
    if grep -qF -- "$needle" <<< "$haystack"; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected to contain: $needle"
        echo "    actual output: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

# ---------------------------------------------------------------------------
#   Mocks: secret-tool (file-backed), az, bw
# ---------------------------------------------------------------------------

MOCK_DIR="$(mktemp -d)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR" "$WORK_DIR"' EXIT
export MOCK_STORE="$MOCK_DIR/store"
: > "$MOCK_STORE"

cat > "$MOCK_DIR/secret-tool" <<'MOCK'
#!/usr/bin/env bash
# Minimal secret-tool: lines of "service<TAB>key<TAB>value" in $MOCK_STORE
cmd="$1"; shift
[[ "${1:-}" == --label=* ]] && shift
[[ "${1:-}" == --all ]] && shift
svc="$2"; key="${4:-}"
case "$cmd" in
    lookup)
        awk -F'\t' -v s="$svc" -v k="$key" '$1==s && $2==k {printf "%s", $3; found=1} END {exit !found}' "$MOCK_STORE"
        ;;
    store)
        value="$(cat)"
        grep -v -P "^\Q$svc\E\t\Q$key\E\t" "$MOCK_STORE" > "$MOCK_STORE.tmp" || true
        printf '%s\t%s\t%s\n' "$svc" "$key" "$value" >> "$MOCK_STORE.tmp"
        mv "$MOCK_STORE.tmp" "$MOCK_STORE"
        ;;
    clear)
        grep -v -P "^\Q$svc\E\t\Q$key\E\t" "$MOCK_STORE" > "$MOCK_STORE.tmp" || true
        mv "$MOCK_STORE.tmp" "$MOCK_STORE"
        ;;
    search)
        awk -F'\t' -v s="$svc" '$1==s {print "attribute.key = " $2}' "$MOCK_STORE" >&2
        ;;
esac
MOCK

cat > "$MOCK_DIR/az" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    "account show"*) echo '{"id":"00000000-0000-0000-0000-000000000000"}' ;;
    "account set"*) exit 0 ;;
    *"--vault-name kv-home --name caddy-client-secret"*) echo "kv-caddy-secret" ;;
    *"--vault-name kv-home --name pve-token"*) echo "kv-pve-token" ;;
    *) exit 1 ;;
esac
MOCK

cat > "$MOCK_DIR/bw" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
    "status") echo '{"status":"unlocked"}' ;;
    "get password homelab/grafana") printf 'bw-grafana-pass' ;;
    "get item homelab/tmdb") echo '{"fields":[{"name":"api_key","value":"bw-tmdb-key"}]}' ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$MOCK_DIR"/*
export PATH="$MOCK_DIR:$PATH"

# Seed the "local wallet": only the Grafana user lives there
printf 'homelab\tgrafana-user\twallet-admin\n' >> "$MOCK_STORE"

cp "$MANIFEST" "$WORK_DIR/.secrets-manifest.yml"
cd "$WORK_DIR"

# ---------------------------------------------------------------------------
#   Tests
# ---------------------------------------------------------------------------

echo "=== fetch-plan normalization ==="

plan_json=$(python3 "$REPO_ROOT/lib/manifest.py" .secrets-manifest.yml fetch-plan caddy)
assert_eq "chain keeps declared order" "wallet,keyvault" \
    "$(python3 -c "import json,sys; e=json.loads(sys.stdin.readline()); print(','.join(s['source'] for s in e['sources']))" <<< "$plan_json")"
assert_eq "alias azure-keyvault -> keyvault" "keyvault" \
    "$(python3 "$REPO_ROOT/lib/manifest.py" .secrets-manifest.yml fetch-plan terraform | python3 -c "import json,sys; print(json.loads(sys.stdin.readline())['sources'][0]['source'])")"

echo "=== plan ==="

plan_out=$(bash "$CLI" plan caddy)
assert_contains "plan shows fallback row" "keyvault" "$plan_out"
assert_contains "plan shows wallet resource" "homelab/caddy-client-secret" "$plan_out"

echo "=== fetch: wallet miss falls back to keyvault ==="

fetch_out=$(bash "$CLI" sync caddy)
assert_contains "falls back to keyvault" "AZURE_CLIENT_SECRET from keyvault... OK" "$fetch_out"
assert_contains "dotenv has fetched value" "AZURE_CLIENT_SECRET=kv-caddy-secret" "$(cat .env.caddy)"
assert_contains "dotenv has static value" "AZURE_TENANT_ID=tenant-1" "$(cat .env.caddy)"

echo "=== fetch: wallet + bitwarden ==="

fetch_out=$(bash "$CLI" sync torrent)
assert_contains "wallet hit" "GRAFANA_USER from wallet... OK" "$fetch_out"
assert_contains "bitwarden password" "GRAFANA_PASSWORD from bitwarden... OK" "$fetch_out"
assert_contains "bitwarden custom field" "TMDB_API_KEY=bw-tmdb-key" "$(cat .env.torrent)"
assert_contains "wallet value in dotenv" "GRAFANA_USER=wallet-admin" "$(cat .env.torrent)"

echo "=== --source filter ==="

filter_out=$(bash "$CLI" --source wallet fetch torrent || true)
assert_contains "non-wallet secrets skipped" "GRAFANA_PASSWORD... SKIP (no wallet source)" "$filter_out"
assert_contains "summary counts skips" "skipped 2" "$filter_out"

filter_out=$(SECRETS_BRIDGE_SOURCE=keyvault bash "$CLI" fetch caddy)
assert_contains "env var filter forces keyvault" "AZURE_CLIENT_SECRET from keyvault... OK" "$filter_out"

echo "=== failure reporting ==="

rc=0
fail_out=$(bash "$CLI" fetch broken) || rc=$?
assert_eq "exit 1 when nothing resolves" "1" "$rc"
assert_contains "lists every source tried" "from wallet -> bitwarden... FAILED" "$fail_out"

echo "=== validate ==="

validate_out=$(bash "$CLI" validate)
assert_contains "wallet backend reported" "Provider check (wallet): backend libsecret" "$validate_out"
assert_contains "bw reported" "Provider check (bitwarden): bw CLI found" "$validate_out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
