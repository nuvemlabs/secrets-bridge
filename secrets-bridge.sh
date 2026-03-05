#!/bin/bash
set -euo pipefail

BRIDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE_VERSION="1.0.0"

# ---------------------------------------------------------------------------
#   Dependency: nuvemlabs/secrets library
# ---------------------------------------------------------------------------

_secrets_lib_found=false

# 1. Installed location
if [[ -f "$HOME/.local/lib/secrets/secrets.sh" ]]; then
    source "$HOME/.local/lib/secrets/secrets.sh"
    _secrets_lib_found=true
# 2. User override via environment variable
elif [[ -n "${SECRETS_LIB_PATH:-}" && -f "$SECRETS_LIB_PATH" ]]; then
    source "$SECRETS_LIB_PATH"
    _secrets_lib_found=true
# 3. Development location (sibling repo)
elif [[ -f "$HOME/repos/secrets/secrets.sh" ]]; then
    source "$HOME/repos/secrets/secrets.sh"
    _secrets_lib_found=true
fi

if [[ "$_secrets_lib_found" != true ]]; then
    echo "Error: nuvemlabs/secrets library not found." >&2
    echo "" >&2
    echo "Install it from: https://github.com/nuvemlabs/secrets" >&2
    echo "  git clone https://github.com/nuvemlabs/secrets.git" >&2
    echo "  cd secrets && bash install.sh" >&2
    echo "" >&2
    echo "Or set SECRETS_LIB_PATH to the path of secrets.sh" >&2
    exit 1
fi
unset _secrets_lib_found

# ---------------------------------------------------------------------------
#   Source components
# ---------------------------------------------------------------------------

source "$BRIDGE_DIR/providers/azure.sh"
source "$BRIDGE_DIR/outputs/postman.sh"
source "$BRIDGE_DIR/outputs/bruno.sh"
source "$BRIDGE_DIR/outputs/dotenv.sh"

# ---------------------------------------------------------------------------
#   Manifest discovery
# ---------------------------------------------------------------------------

_MANIFEST_PATH=""

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
  --version         Print version
  --help            Show this help message

Examples:
  secrets-bridge validate
  secrets-bridge plan sit
  secrets-bridge sync sit
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

    # Check provider tools
    if [[ "$default_provider" == "azure" ]]; then
        if command -v az &>/dev/null; then
            echo "Provider check: az CLI found"
        else
            echo "Provider check: az CLI NOT found (required for Azure provider)"
        fi
    fi

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

    local secrets_json
    secrets_json=$(_parse_manifest secrets "$env")

    echo "Project: $project | Environment: $env | Provider: $default_provider"
    echo ""

    # Print table header
    printf "  %-35s %-20s %s\n" "NAME" "SOURCE" "RESOURCE"
    echo ""

    local total=0 to_fetch=0 static_count=0

    # Parse each secret and print a row
    python3 -c "
import json, sys
secrets = json.loads(sys.argv[1])
total = len(secrets)
fetch_count = 0
static_count = 0
for s in secrets:
    name = s.get('name', '')
    source = s.get('source', '')
    value = s.get('value', '')
    is_static = bool(value) and not source

    if is_static:
        static_count += 1
        # Truncate static values for display
        display_val = value if len(str(value)) <= 30 else str(value)[:27] + '...'
        print(f'  {name:<35s} {\"static\":<20s} {display_val}')
    elif source == 'keyvault':
        fetch_count += 1
        vault = s.get('vault', '')
        secret_name = s.get('secret', '')
        print(f'  {name:<35s} {source:<20s} {vault}/{secret_name}')
    elif source == 'apim-subscription':
        fetch_count += 1
        rg = s.get('resource_group', '')
        svc = s.get('service', '')
        sub_id = s.get('subscription_id', '')
        key = s.get('key', 'primary')
        print(f'  {name:<35s} {source:<20s} {svc}/{sub_id} ({key})')
    elif source == 'apim-named-value':
        fetch_count += 1
        rg = s.get('resource_group', '')
        svc = s.get('service', '')
        nv_id = s.get('named_value_id', '')
        print(f'  {name:<35s} {source:<20s} {svc}/{nv_id}')
    else:
        fetch_count += 1
        print(f'  {name:<35s} {source:<20s} (unknown)')

print()
print(f'  {total} secrets ({fetch_count} to fetch, {static_count} static)')
" "$secrets_json"
}

cmd_fetch() {
    local env="$1"
    [[ -z "$env" ]] && { echo "Usage: secrets-bridge fetch <env>" >&2; return 1; }
    _find_manifest || return 1

    local project_json
    project_json=$(_parse_manifest project)
    local project
    project=$(echo "$project_json" | python3 -c "import sys,json; print(json.load(sys.stdin).get('project',''))")

    # Set keychain namespace for isolation
    SECRETS_SERVICE="secrets-bridge:${project}"

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

    local secrets_json
    secrets_json=$(_parse_manifest secrets "$env")

    local total fetched=0 static_count=0 failed=0
    total=$(echo "$secrets_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")

    local idx=0
    while IFS= read -r secret_line; do
        idx=$((idx + 1))
        local name source value is_secret vault secret_name rg service sub_id key nv_id

        name=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('name',''))")
        source=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('source',''))")
        value=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''))")
        is_secret=$(echo "$secret_line" | python3 -c "import sys,json; d=json.load(sys.stdin); print('false' if d.get('secret') == False else 'true')")

        # Static value (has value field, no source)
        if [[ -n "$value" && -z "$source" ]]; then
            printf "[%d/%d] Static %s... " "$idx" "$total" "$name"
            secret_set "$name" "$value"
            echo "OK"
            static_count=$((static_count + 1))
            continue
        fi

        printf "[%d/%d] Fetching %s from %s... " "$idx" "$total" "$name" "$source"

        local fetched_value=""
        case "$source" in
            keyvault)
                vault=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('vault',''))")
                secret_name=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('secret',''))")
                fetched_value=$(provider_azure_fetch keyvault "$vault" "$secret_name" 2>/dev/null) || true
                ;;
            apim-subscription)
                rg=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('resource_group',''))")
                service=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('service',''))")
                sub_id=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('subscription_id',''))")
                key=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key','primary'))")
                fetched_value=$(provider_azure_fetch apim-subscription "$rg" "$service" "$sub_id" "$key" 2>/dev/null) || true
                ;;
            apim-named-value)
                rg=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('resource_group',''))")
                service=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('service',''))")
                nv_id=$(echo "$secret_line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('named_value_id',''))")
                fetched_value=$(provider_azure_fetch apim-named-value "$rg" "$service" "$nv_id" 2>/dev/null) || true
                ;;
            *)
                echo "SKIP (unknown source: $source)"
                failed=$((failed + 1))
                continue
                ;;
        esac

        if [[ -n "$fetched_value" ]]; then
            secret_set "$name" "$fetched_value"
            echo "OK"
            fetched=$((fetched + 1))
        else
            echo "FAILED"
            failed=$((failed + 1))
        fi
    done < <(echo "$secrets_json" | python3 -c "
import json, sys
secrets = json.load(sys.stdin)
for s in secrets:
    print(json.dumps(s))
")

    echo ""
    echo "Fetched $fetched, static $static_count, failed $failed"

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
" "$resolved_json" "$SECRETS_SERVICE" "$(
    # Find secrets.sh path
    if [[ -f "$HOME/.local/lib/secrets/secrets.sh" ]]; then
        echo "$HOME/.local/lib/secrets/secrets.sh"
    elif [[ -n "${SECRETS_LIB_PATH:-}" && -f "$SECRETS_LIB_PATH" ]]; then
        echo "$SECRETS_LIB_PATH"
    elif [[ -f "$HOME/repos/secrets/secrets.sh" ]]; then
        echo "$HOME/repos/secrets/secrets.sh"
    fi
)")

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
