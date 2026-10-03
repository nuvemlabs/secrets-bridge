#!/usr/bin/env bash
# Bitwarden provider for secrets-bridge.
# Reads items from a Bitwarden (or Vaultwarden) vault with the official `bw` CLI.
# The vault must be unlocked: export BW_SESSION="$(bw unlock --raw)".
#
# Manifest fields:
#   item   item name or id (as accepted by `bw get item`)
#   field  password (default) | username | notes | totp | <custom field name>

provider_bitwarden_check() {
    if ! command -v bw &>/dev/null; then
        echo "Error: Bitwarden CLI (bw) is not installed" >&2
        return 1
    fi
    local status
    status=$(bw status 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
    if [[ "$status" != "unlocked" ]]; then
        echo "Error: Bitwarden vault is ${status:-unavailable}. Run: export BW_SESSION=\"\$(bw unlock --raw)\"" >&2
        return 1
    fi
}

provider_bitwarden_fetch() {
    local item="$1" field="${2:-password}"
    [[ -z "$item" ]] && { echo "Error: bitwarden item required" >&2; return 1; }
    case "$field" in
        password|username|notes|totp)
            bw get "$field" "$item" 2>/dev/null
            ;;
        *)
            # Custom field: read it from the item JSON inside python so the
            # value only ever travels on stdout.
            bw get item "$item" 2>/dev/null | python3 -c "
import json, sys
field = sys.argv[1]
item = json.load(sys.stdin)
for f in item.get('fields') or []:
    if f.get('name') == field:
        sys.stdout.write(f.get('value') or '')
        sys.exit(0)
sys.exit(1)
" "$field"
            ;;
    esac
}
