#!/usr/bin/env bash
# Local wallet provider for secrets-bridge.
# Reads secrets the user already keeps in the OS wallet through the
# nuvemlabs/secrets library, which picks the backend per platform:
#   macOS   -> Keychain (security)
#   Linux   -> libsecret (secret-tool: GNOME Keyring / KWallet via Secret Service)
#   Windows -> Credential Manager
#
# Manifest fields:
#   service  wallet namespace the value lives in (default: $SECRETS_BRIDGE_WALLET_SERVICE,
#            else "secrets", the library default)
#   key      entry name inside that namespace (default: the manifest secret name)

: "${SECRETS_BRIDGE_WALLET_SERVICE:=secrets}"

# The wallet is usable when the secrets library resolved a native backend.
provider_wallet_check() {
    if ! declare -F secret &>/dev/null; then
        echo "Error: nuvemlabs/secrets library not loaded" >&2
        return 1
    fi
    if [[ "${__SECRETS_BACKEND:-file}" == "file" ]]; then
        echo "Warning: no native wallet found (secret-tool / security); using file backend" >&2
    fi
}

# Print the native backend name (keychain, libsecret, credmanager, file).
provider_wallet_backend() {
    echo "${__SECRETS_BACKEND:-unknown}"
}

# Fetch one value. Runs in a subshell so the caller's SECRETS_SERVICE
# (the secrets-bridge cache namespace) is never changed.
provider_wallet_fetch() {
    local service="${1:-$SECRETS_BRIDGE_WALLET_SERVICE}" key="$2"
    [[ -z "$key" ]] && { echo "Error: wallet key required" >&2; return 1; }
    (
        # shellcheck disable=SC2034  # read by secret()
        SECRETS_SERVICE="$service"
        secret "$key"
    )
}
