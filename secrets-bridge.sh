#!/bin/bash
set -euo pipefail

# Follow a symlink chain to the real file. Relative targets resolve against
# the link's own directory (Homebrew links are relative).
_resolve_link() {
    local path="$1" target
    while [[ -L "$path" ]]; do
        target="$(readlink "$path")"
        if [[ "$target" == /* ]]; then
            path="$target"
        else
            path="$(dirname "$path")/$target"
        fi
    done
    echo "$path"
}

BRIDGE_DIR="$(cd "$(dirname "$(_resolve_link "${BASH_SOURCE[0]}")")" && pwd)"
BRIDGE_VERSION="1.1.0"

# ---------------------------------------------------------------------------
#   Dependency: nuvemlabs/secrets library
# ---------------------------------------------------------------------------

# Print the path of the secrets library, first match wins:
#   1. SECRETS_LIB_PATH (explicit override)
#   2. ~/.local/lib/secrets (per-user install.sh)
#   3. next to the secrets-doctor on PATH: every install, packaged or not,
#      puts the CLI in <prefix>/bin and the library in <prefix>/lib/secrets
#   4. ~/repos/secrets (development checkout)
_find_secrets_lib() {
    if [[ -n "${SECRETS_LIB_PATH:-}" ]]; then
        if [[ -f "$SECRETS_LIB_PATH" ]]; then
            echo "$SECRETS_LIB_PATH"
            return 0
        fi
        echo "Warning: SECRETS_LIB_PATH=$SECRETS_LIB_PATH does not exist; searching the usual places" >&2
    fi
    if [[ -f "$HOME/.local/lib/secrets/secrets.sh" ]]; then
        echo "$HOME/.local/lib/secrets/secrets.sh"
        return 0
    fi
    local doctor candidate
    if doctor="$(command -v secrets-doctor 2>/dev/null)"; then
        candidate="$(dirname "$(_resolve_link "$doctor")")/../lib/secrets/secrets.sh"
        if [[ -f "$candidate" ]]; then
            echo "$(cd "$(dirname "$candidate")" && pwd)/secrets.sh"
            return 0
        fi
    fi
    if [[ -f "$HOME/repos/secrets/secrets.sh" ]]; then
        echo "$HOME/repos/secrets/secrets.sh"
        return 0
    fi
    return 1
}

if ! SECRETS_LIB_FILE="$(_find_secrets_lib)"; then
    echo "Error: nuvemlabs/secrets library not found." >&2
    echo "" >&2
    echo "Install it from: https://github.com/nuvemlabs/secrets" >&2
    echo "  brew install nuvemlabs/tap/secrets" >&2
    echo "  or: git clone https://github.com/nuvemlabs/secrets.git && cd secrets && bash install.sh" >&2
    echo "" >&2
    echo "Or set SECRETS_LIB_PATH to the path of secrets.sh" >&2
    exit 1
fi
[[ "${SECRETS_BRIDGE_DEBUG_LIB:-0}" == "1" ]] && echo "secrets lib: $SECRETS_LIB_FILE" >&2
# shellcheck source=/dev/null
source "$SECRETS_LIB_FILE"

# ---------------------------------------------------------------------------
#   Source components
# ---------------------------------------------------------------------------

source "$BRIDGE_DIR/providers/azure.sh"
source "$BRIDGE_DIR/providers/wallet.sh"
source "$BRIDGE_DIR/providers/bitwarden.sh"
source "$BRIDGE_DIR/outputs/postman.sh"
source "$BRIDGE_DIR/outputs/bruno.sh"
source "$BRIDGE_DIR/outputs/dotenv.sh"

# ---------------------------------------------------------------------------
#   Manifest discovery
# ---------------------------------------------------------------------------

_MANIFEST_PATH=""
# Restrict fetch/plan to one source type (--source or SECRETS_BRIDGE_SOURCE)
_SOURCE_FILTER="${SECRETS_BRIDGE_SOURCE:-}"

_find_manifest() {
    if [[ -n "$_MANIFEST_PATH" ]]; then
        return 0
    fi
    if [[ -f ".secrets-manifest.yml" ]]; then
        _MANIFEST_PATH="$(pwd)/.secrets-manifest.yml"
    else
        echo "Error: No .secrets-manifest.yml found in current directory." >&2
        echo "Use --manifest <path> to specify a manifest file." >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
#   Helpers
# ---------------------------------------------------------------------------

_parse_manifest() {
    local command="$1"
    shift
    python3 "$BRIDGE_DIR/lib/manifest.py" "$_MANIFEST_PATH" "$command" "$@"
}

_print_usage() {
    cat <<EOF
secrets-bridge v${BRIDGE_VERSION} - Cloud-to-local secret bridging

Usage: secrets-bridge [options] <command> [args]

Commands:
  validate          Check manifest syntax and provider prerequisites
  plan <env>        Preview what would be fetched (dry run)
  fetch <env>       Fetch secrets from cloud providers into local keychain
  generate <env>    Generate output files from cached secrets
  sync <env>        Fetch then generate (fetch + generate)
  status <env>      Show which secrets are cached vs missing

Options:
  --manifest <path> Path to manifest file (default: ./.secrets-manifest.yml)
  --source <type>   Only use this source type: wallet, keyvault, bitwarden,
                    apim-subscription, apim-named-value (env: SECRETS_BRIDGE_SOURCE)
  --version         Print version
  --help            Show this help message

Sources:
  keyvault          Azure Key Vault (az CLI)           fields: vault, secret
  wallet            Local OS wallet: macOS Keychain,   fields: service, key
                    Linux libsecret, Windows CredMgr
  bitwarden         Bitwarden/Vaultwarden (bw CLI)     fields: item, field
  apim-subscription Azure APIM subscription key
  apim-named-value  Azure APIM named value
  A secret may list several under 'sources:'; they are tried in order.

Examples:
  secrets-bridge validate
  secrets-bridge plan sit
  secrets-bridge sync sit
  secrets-bridge --source wallet sync sit
  secrets-bridge status sit
EOF
}

# ---------------------------------------------------------------------------
#   Commands
# ---------------------------------------------------------------------------

cmd_validate() {
    _find_manifest || return 1

    # Parse project info
    local project_json
    project_json=$(_parse_manifest project) || {
        echo "Error: Failed to parse manifest." >&2
        return 1
    }

    local project default_provider
    project=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project',''))")
    default_provider=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_provider',''))")

    # Parse environment list
    local envs_json
    envs_json=$(_parse_manifest envs) || {
        echo "Error: Failed to parse environments." >&2
        return 1
    }

    local env_count
    env_count=$(echo "$envs_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    echo "Manifest: $_MANIFEST_PATH"
    echo "Project:  $project"
    echo "Provider: $default_provider"
    echo ""

    # Check the tool behind every source type the manifest uses
    local used_sources
    used_sources=$(echo "$envs_json" | python3 -c "
import json, subprocess, sys
used = set()
for env in json.load(sys.stdin):
    out = subprocess.run([sys.executable, sys.argv[1], sys.argv[2], 'fetch-plan', env],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        for sp in json.loads(line)['sources']:
            used.add(sp['source'])
print(' '.join(sorted(used)))
" "$BRIDGE_DIR/lib/manifest.py" "$_MANIFEST_PATH")
    [[ "$default_provider" == "azure" ]] && used_sources+=" keyvault"

    local src
    for src in $(tr ' ' '\n' <<< "$used_sources" | sort -u); do
        case "$src" in
            keyvault|apim-subscription|apim-named-value)
                command -v az &>/dev/null \
                    && echo "Provider check ($src): az CLI found" \
                    || echo "Provider check ($src): az CLI NOT found"
                ;;
            wallet)
                echo "Provider check (wallet): backend $(provider_wallet_backend)"
                ;;
            bitwarden)
                command -v bw &>/dev/null \
                    && echo "Provider check (bitwarden): bw CLI found" \
                    || echo "Provider check (bitwarden): bw CLI NOT found"
                ;;
            *)
                echo "Provider check ($src): UNKNOWN source type" >&2
                return 1
                ;;
        esac
    done

    echo ""
    echo "Environments ($env_count):"

    # For each environment, count secrets
    local envs_list
    envs_list=$(echo "$envs_json" | python3 -c "import sys,json
for e in json.load(sys.stdin): print(e)")

    while IFS= read -r env_name; do
        local secrets_json
        secrets_json=$(_parse_manifest secrets "$env_name")
        local secret_count
        secret_count=$(echo "$secrets_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
        echo "  $env_name: $secret_count secrets"
    done <<< "$envs_list"

    echo ""
    echo "Manifest is valid."
}

cmd_plan() {
    local env="$1"
    [[ -z "$env" ]] && { echo "Usage: secrets-bridge plan <env>" >&2; return 1; }
    _find_manifest || return 1

    local project_json
    project_json=$(_parse_manifest project)
    local project default_provider
    project=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project',''))")
    default_provider=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('default_provider',''))")

    local plan_lines
    plan_lines=$(_parse_manifest fetch-plan "$env" "$_SOURCE_FILTER") || return 1

    echo "Project: $project | Environment: $env | Provider: $default_provider${_SOURCE_FILTER:+ | Source filter: $_SOURCE_FILTER}"
    echo ""
    printf "  %-35s %-20s %s\n" "NAME" "SOURCE" "RESOURCE"
    echo ""

    printf '%s\n' "$plan_lines" | python3 -c "
import json, sys

def describe(sp):
    src = sp.get('source', '')
    if src == 'keyvault':
        return f\"{sp.get('vault', '')}/{sp.get('secret', '')}\"
    if src == 'apim-subscription':
        sub = sp.get('azure_subscription', '')
        extra = f' [{sub}]' if sub else ''
        return f\"{sp.get('service', '')}/{sp.get('subscription_id', '')} ({sp.get('key', 'primary')}){extra}\"
    if src == 'apim-named-value':
        return f\"{sp.get('service', '')}/{sp.get('named_value_id', '')}\"
    if src == 'wallet':
        svc = sp.get('service') or sys.argv[1]
        return f\"{svc}/{sp.get('key', '')}\"
    if src == 'bitwarden':
        return f\"{sp.get('item', '')} ({sp.get('field', 'password')})\"
    return '(unknown)'

total = fetch_count = static_count = skip_count = 0
for line in sys.stdin:
    if not line.strip():
        continue
    e = json.loads(line)
    total += 1
    name = e['name']
    if e['static']:
        static_count += 1
        v = e['value']
        shown = v if len(v) <= 30 else v[:27] + '...'
        print(f'  {name:<35s} {\"static\":<20s} {shown}')
        continue
    specs = e['sources']
    if not specs:
        skip_count += 1
        print(f'  {name:<35s} {\"(skipped)\":<20s} no matching source')
        continue
    fetch_count += 1
    for i, sp in enumerate(specs):
        label = name if i == 0 else '  or'
        print(f'  {label:<35s} {sp[\"source\"]:<20s} {describe(sp)}')

print()
print(f'  {total} secrets ({fetch_count} to fetch, {static_count} static, {skip_count} skipped)')
" "$SECRETS_BRIDGE_WALLET_SERVICE"
}

# Read one field from a JSON object: _jget <json> <key> [default]
_jget() {
    python3 -c "
import json, sys
v = json.loads(sys.argv[1]).get(sys.argv[2], sys.argv[3])
print('' if v is None else v)
" "$1" "$2" "${3:-}"
}

# Fetch one value from one source spec (JSON). Prints the value on stdout.
# $2 is the environment's default Azure subscription.
_fetch_from_spec() {
    local spec="$1" env_subscription="$2"
    local source
    source=$(_jget "$spec" source)

    case "$source" in
        keyvault|apim-subscription|apim-named-value)
            local spec_subscription
            spec_subscription=$(_jget "$spec" azure_subscription)
            if [[ -n "$spec_subscription" && "$spec_subscription" != "$env_subscription" ]]; then
                provider_azure_set_subscription "$spec_subscription" || return 1
            fi
            local rc=0
            case "$source" in
                keyvault)
                    provider_azure_fetch keyvault "$(_jget "$spec" vault)" "$(_jget "$spec" secret)" || rc=$?
                    ;;
                apim-subscription)
                    provider_azure_fetch apim-subscription "$(_jget "$spec" resource_group)" \
                        "$(_jget "$spec" service)" "$(_jget "$spec" subscription_id)" \
                        "$(_jget "$spec" key primary)" || rc=$?
                    ;;
                apim-named-value)
                    provider_azure_fetch apim-named-value "$(_jget "$spec" resource_group)" \
                        "$(_jget "$spec" service)" "$(_jget "$spec" named_value_id)" || rc=$?
                    ;;
            esac
            # Switch back to the environment subscription if we changed it
            if [[ -n "$spec_subscription" && "$spec_subscription" != "$env_subscription" && -n "$env_subscription" ]]; then
                provider_azure_set_subscription "$env_subscription" &>/dev/null
            fi
            return "$rc"
            ;;
        wallet)
            provider_wallet_fetch "$(_jget "$spec" service "$SECRETS_BRIDGE_WALLET_SERVICE")" "$(_jget "$spec" key)"
            ;;
        bitwarden)
            provider_bitwarden_fetch "$(_jget "$spec" item)" "$(_jget "$spec" field password)"
            ;;
        *)
            echo "Error: unknown source '$source'" >&2
            return 1
            ;;
    esac
}

cmd_fetch() {
    local env="$1"
    [[ -z "$env" ]] && { echo "Usage: secrets-bridge fetch <env>" >&2; return 1; }
    _find_manifest || return 1

    local project_json
    project_json=$(_parse_manifest project)
    local project
    project=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project',''))")

    # Parse Azure config and set subscription
    local azure_json
    azure_json=$(_parse_manifest azure-config "$env")
    local subscription
    subscription=$(echo "$azure_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscription',''))")
    if [[ -n "$subscription" ]]; then
        provider_azure_set_subscription "$subscription" || {
            echo "Error: Failed to set Azure subscription '$subscription'" >&2
            return 1
        }
    fi

    local plan_lines
    plan_lines=$(_parse_manifest fetch-plan "$env" "$_SOURCE_FILTER") || return 1

    # Set keychain namespace for isolation. Wallet reads use their own
    # namespace in a subshell, so this cache namespace is never disturbed.
    SECRETS_SERVICE="secrets-bridge:${project}"

    local total fetched=0 static_count=0 failed=0 skipped=0
    total=$(printf '%s\n' "$plan_lines" | grep -c . || true)

    [[ -n "$_SOURCE_FILTER" ]] && echo "Source filter: $_SOURCE_FILTER"

    local idx=0 entry
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        idx=$((idx + 1))
        local name is_static value
        name=$(_jget "$entry" name)
        is_static=$(_jget "$entry" static)

        # Static value (has value key in manifest, no source)
        if [[ "$is_static" == "True" ]]; then
            value=$(_jget "$entry" value)
            printf "[%d/%d] Static %s... " "$idx" "$total" "$name"
            if [[ -n "$value" ]]; then
                secret_set "$name" "$value"
            fi
            echo "OK"
            static_count=$((static_count + 1))
            continue
        fi

        local specs
        specs=$(python3 -c "
import json, sys
for s in json.loads(sys.argv[1])['sources']:
    print(json.dumps(s))
" "$entry")

        if [[ -z "$specs" ]]; then
            printf "[%d/%d] %s... SKIP (no %s source)\n" "$idx" "$total" "$name" "${_SOURCE_FILTER:-matching}"
            skipped=$((skipped + 1))
            continue
        fi

        printf "[%d/%d] Fetching %s" "$idx" "$total" "$name"
        local fetched_value="" spec source tried=""
        while IFS= read -r spec; do
            source=$(_jget "$spec" source)
            tried+="${tried:+ -> }$source"
            fetched_value=$(_fetch_from_spec "$spec" "$subscription" 2>/dev/null) || fetched_value=""
            [[ -n "$fetched_value" ]] && break
        done <<< "$specs"

        if [[ -n "$fetched_value" ]]; then
            secret_set "$name" "$fetched_value"
            echo " from $source... OK"
            fetched=$((fetched + 1))
        else
            echo " from $tried... FAILED"
            failed=$((failed + 1))
        fi
        fetched_value=""
    done <<< "$plan_lines"

    echo ""
    echo "Fetched $fetched, static $static_count, skipped $skipped, failed $failed"

    if [[ "$failed" -gt 0 ]]; then
        return 1
    fi
}

cmd_generate() {
    local env="$1"
    [[ -z "$env" ]] && { echo "Usage: secrets-bridge generate <env>" >&2; return 1; }
    _find_manifest || return 1

    local project_json
    project_json=$(_parse_manifest project)
    local project
    project=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project',''))")

    # Set keychain namespace for reading
    SECRETS_SERVICE="secrets-bridge:${project}"

    local secrets_json
    secrets_json=$(_parse_manifest secrets "$env")
    local outputs_json
    outputs_json=$(_parse_manifest outputs "$env")

    # Build secrets array with resolved values
    local resolved_json
    resolved_json=$(python3 -c "
import json, sys, subprocess

secrets = json.loads(sys.argv[1])
project = sys.argv[2]

resolved = []
for s in secrets:
    name = s.get('name', '')
    is_secret = s.get('secret', True)
    if is_secret == False:
        is_secret_bool = False
    else:
        is_secret_bool = True
    resolved.append({
        'name': name,
        'value': '',  # placeholder
        'secret': is_secret_bool
    })

print(json.dumps(resolved))
" "$secrets_json" "$project")

    # Read each secret value from keychain
    local final_json
    final_json=$(python3 -c "
import json, sys, subprocess, os

resolved = json.loads(sys.argv[1])
service = sys.argv[2]
secrets_lib = sys.argv[3]

for entry in resolved:
    name = entry['name']
    try:
        result = subprocess.run(
            ['bash', '-c', f'export SECRETS_SERVICE=\"{service}\"; source \"{secrets_lib}\"; secret \"{name}\"'],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            entry['value'] = result.stdout.strip()
    except Exception:
        pass

print(json.dumps(resolved))
" "$resolved_json" "$SECRETS_SERVICE" "$SECRETS_LIB_FILE")

    # Generate each output
    while IFS= read -r output_line; do
        local format file_path
        format=$(echo "$output_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('format',''))")
        file_path=$(echo "$output_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('file',''))")

        case "$format" in
            postman)
                output_postman_generate "$project" "$env" "$file_path" "$final_json"
                echo "Generated $file_path (postman)"
                ;;
            bruno)
                output_bruno_generate "$project" "$env" "$file_path" "$final_json"
                echo "Generated $file_path (bruno)"
                ;;
            dotenv)
                output_dotenv_generate "$project" "$env" "$file_path" "$final_json"
                echo "Generated $file_path (dotenv)"
                ;;
            *)
                echo "Warning: Unknown output format '$format', skipping" >&2
                ;;
        esac
    done < <(echo "$outputs_json" | python3 -c "
import json, sys
outputs = json.load(sys.stdin)
for o in outputs:
    print(json.dumps(o))
")
}

cmd_sync() {
    local env="$1"
    [[ -z "$env" ]] && { echo "Usage: secrets-bridge sync <env>" >&2; return 1; }

    cmd_fetch "$env" || return 1
    echo ""
    cmd_generate "$env"
}

cmd_status() {
    local env="$1"
    [[ -z "$env" ]] && { echo "Usage: secrets-bridge status <env>" >&2; return 1; }
    _find_manifest || return 1

    local project_json
    project_json=$(_parse_manifest project)
    local project
    project=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project',''))")

    # Set keychain namespace
    SECRETS_SERVICE="secrets-bridge:${project}"

    local secrets_json
    secrets_json=$(_parse_manifest secrets "$env")

    echo "Project: $project | Environment: $env"
    echo ""
    printf "  %-35s %s\n" "NAME" "STATUS"
    echo ""

    local cached=0 missing=0

    # Find secrets.sh path for subprocess calls
    local secrets_sh_path=""
    if [[ -f "$HOME/.local/lib/secrets/secrets.sh" ]]; then
        secrets_sh_path="$HOME/.local/lib/secrets/secrets.sh"
    elif [[ -n "${SECRETS_LIB_PATH:-}" && -f "$SECRETS_LIB_PATH" ]]; then
        secrets_sh_path="$SECRETS_LIB_PATH"
    elif [[ -f "$HOME/repos/secrets/secrets.sh" ]]; then
        secrets_sh_path="$HOME/repos/secrets/secrets.sh"
    fi

    while IFS= read -r secret_line; do
        local name
        name=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))")

        # Check if secret exists in keychain
        local has_value=false
        if bash -c "export SECRETS_SERVICE='$SECRETS_SERVICE'; source '$secrets_sh_path'; secret '$name'" &>/dev/null; then
            has_value=true
        fi

        if [[ "$has_value" == true ]]; then
            printf "  %-35s cached\n" "$name"
            cached=$((cached + 1))
        else
            printf "  %-35s missing\n" "$name"
            missing=$((missing + 1))
        fi
    done < <(echo "$secrets_json" | python3 -c "
import json, sys
secrets = json.load(sys.stdin)
for s in secrets:
    print(json.dumps(s))
")

    echo ""
    echo "  $cached cached, $missing missing"
}

# ---------------------------------------------------------------------------
#   Argument parsing
# ---------------------------------------------------------------------------

main() {
    local command=""
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version)
                echo "secrets-bridge v${BRIDGE_VERSION}"
                return 0
                ;;
            --help|-h)
                _print_usage
                return 0
                ;;
            --source)
                shift
                [[ $# -eq 0 ]] && { echo "Error: --source requires a type argument" >&2; return 1; }
                _SOURCE_FILTER="$1"
                shift
                ;;
            --manifest)
                shift
                [[ $# -eq 0 ]] && { echo "Error: --manifest requires a path argument" >&2; return 1; }
                _MANIFEST_PATH="$1"
                if [[ ! -f "$_MANIFEST_PATH" ]]; then
                    echo "Error: Manifest file not found: $_MANIFEST_PATH" >&2
                    return 1
                fi
                shift
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                echo "Run 'secrets-bridge --help' for usage." >&2
                return 1
                ;;
            *)
                if [[ -z "$command" ]]; then
                    command="$1"
                else
                    args+=("$1")
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$command" ]]; then
        _print_usage
        return 0
    fi

    case "$command" in
        validate)  cmd_validate ;;
        plan)      cmd_plan "${args[0]:-}" ;;
        fetch)     cmd_fetch "${args[0]:-}" ;;
        generate)  cmd_generate "${args[0]:-}" ;;
        sync)      cmd_sync "${args[0]:-}" ;;
        status)    cmd_status "${args[0]:-}" ;;
        *)
            echo "Error: Unknown command: $command" >&2
            echo "Run 'secrets-bridge --help' for usage." >&2
            return 1
            ;;
    esac
}

# Only run main if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
