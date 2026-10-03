# secrets-bridge

Fetch secrets from cloud providers and generate local environment files for API testing tools.

![Azure](https://img.shields.io/badge/Azure-Key%20Vault%20%7C%20APIM-0078D4?style=flat-square&logo=microsoft-azure)
![macOS](https://img.shields.io/badge/macOS-Keychain-000000?style=flat-square&logo=apple)
![Linux](https://img.shields.io/badge/Linux-libsecret-FCC624?style=flat-square&logo=linux&logoColor=black)
![Windows](https://img.shields.io/badge/Windows-Credential%20Manager-0078D4?style=flat-square&logo=windows)
![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![Dependencies](https://img.shields.io/badge/dependencies-bash%20%2B%20python3-blue?style=flat-square)

## Problem

API testing tools like Postman and Bruno need environment files with secrets (API keys, client secrets, subscription keys). These secrets live in cloud services like Azure Key Vault and APIM. Manually copying them is error-prone, and committing environment files with real values to git is a security risk.

**secrets-bridge** reads a YAML manifest that declares which secrets to fetch and which output formats to generate. Secrets are cached in your OS-native keychain and output files are generated locally -- never committed to source control.

## Data Flow

```
.secrets-manifest.yml          Cloud Providers
        |                           |
        v                           v
  +-----------+    az CLI    +-------------+
  |  secrets  | -----------> | Key Vault   |
  |  bridge   | -----------> | APIM Subs   |
  |   CLI     | -----------> | APIM NVs    |
  +-----------+              +-------------+
        |                           |
        v                           v
  OS Keychain  <-------- fetched values
  (cached)
        |
        +---> Postman .json
        +---> Bruno .bru
        +---> .env file
```

## Install

| Channel | Command |
|---------|---------|
| Homebrew (macOS, Linux) | `brew install nuvemlabs/tap/secrets-bridge` (pulls in `nuvemlabs/tap/secrets`) |
| Arch (PKGBUILD) | `git clone https://github.com/nuvemlabs/secrets-bridge.git && cd secrets-bridge/packaging/aur && makepkg -si` (needs `nuvemlabs-secrets` installed first, same way) |
| From source (any) | install [nuvemlabs/secrets](https://github.com/nuvemlabs/secrets#install), then `git clone https://github.com/nuvemlabs/secrets-bridge.git && cd secrets-bridge && bash install.sh` |

The CLI finds the secrets library in this order: `SECRETS_LIB_PATH`, `~/.local/lib/secrets`, next to the
`secrets-doctor` on your `PATH` (any packaged install), then `~/repos/secrets`. Set
`SECRETS_BRIDGE_DEBUG_LIB=1` to print which copy it used.

Packagers stage a system layout with `PREFIX=/usr DESTDIR="$pkgdir" bash install.sh`.

## Quick Start

```bash
# 1. Create a manifest in your project
cat > .secrets-manifest.yml <<'YAML'
project: my-api-tests
default_provider: azure

environments:
  sit:
    azure:
      subscription: MY_SUBSCRIPTION_SIT
    secrets:
      - name: api_key
        source: keyvault
        vault: my-keyvault-sit
        secret: api-key
      - name: baseurl
        value: https://sit.example.com
        secret: false
    outputs:
      - format: postman
        file: envs/SIT.postman_environment.json
      - format: dotenv
        file: .env.sit
YAML

# 2. Sync (fetch + generate)
az login
secrets-bridge sync sit
```

## CLI Reference

| Command | Description |
|---------|-------------|
| `secrets-bridge validate` | Check manifest syntax and provider prerequisites |
| `secrets-bridge plan <env>` | Preview what would be fetched (dry run) |
| `secrets-bridge fetch <env>` | Fetch secrets from cloud into local keychain |
| `secrets-bridge generate <env>` | Generate output files from cached secrets |
| `secrets-bridge sync <env>` | Fetch then generate (shorthand) |
| `secrets-bridge status <env>` | Show which secrets are cached vs missing |
| `secrets-bridge --version` | Print version |
| `secrets-bridge --help` | Show usage |

**Options:**

| Option | Description |
|--------|-------------|
| `--manifest <path>` | Path to manifest file (default: `./.secrets-manifest.yml`) |
| `--source <type>` | Only use one source type for this run, e.g. `wallet` or `keyvault` (env: `SECRETS_BRIDGE_SOURCE`). Secrets without that source are skipped, not failed. |

## Manifest Reference

```yaml
# Project identifier (used for keychain namespace isolation)
project: my-project

# Default cloud provider
default_provider: azure

environments:
  sit:
    # Provider-specific config
    azure:
      subscription: MY_AZURE_SUBSCRIPTION

    # Secret definitions
    secrets:
      # Key Vault secret
      - name: client_secret           # Variable name in output files
        source: keyvault               # Provider source type
        vault: my-keyvault-sit         # Key Vault name
        secret: client-secret          # Secret name in Key Vault

      # APIM subscription key
      - name: apim_key
        source: apim-subscription
        resource_group: my-rg-sit      # Azure resource group
        service: my-apim-sit           # APIM service name
        subscription_id: my-sub        # APIM subscription ID
        key: primary                   # primary or secondary

      # APIM named value
      - name: named_val
        source: apim-named-value
        resource_group: my-rg-sit
        service: my-apim-sit
        named_value_id: my-named-value

      # Static value (not fetched from cloud)
      - name: baseurl
        value: https://sit.example.com
        secret: false                  # type=default in Postman

    # Output file definitions
    outputs:
      - format: postman                # Postman environment JSON
        file: envs/SIT.postman_environment.json

      - format: bruno                  # Bruno .bru environment
        file: environments/SIT.bru

      - format: dotenv                 # .env file
        file: .env.sit
```

### Secret Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Variable name used in output files |
| `source` | for fetched secrets | `keyvault`, `wallet`, `bitwarden`, `apim-subscription`, or `apim-named-value` |
| `sources` | alternative to `source` | Ordered list of source specs; the first one that returns a value wins |
| `value` | for static values | Literal value (not fetched from cloud) |
| `secret` | no | `false` marks as non-secret (type=default in Postman). Default: `true` |

**Key Vault fields:** `vault`, `secret`

**APIM subscription fields:** `resource_group`, `service`, `subscription_id`, `key` (primary/secondary)

**APIM named value fields:** `resource_group`, `service`, `named_value_id`

**Wallet fields:** `service` (wallet namespace, default `$SECRETS_BRIDGE_WALLET_SERVICE` or `secrets`), `key`.
Reads the local OS wallet through nuvemlabs/secrets: macOS Keychain, Linux libsecret
(GNOME Keyring / KWallet), Windows Credential Manager. Store a value with
`SECRETS_SERVICE=<service> secret_set <key> <value>`.

**Bitwarden fields:** `item` (name or id), `field` (`password` default, `username`, `notes`, `totp`,
or a custom field name). Needs the `bw` CLI with an unlocked vault (`export BW_SESSION="$(bw unlock --raw)"`).

Aliases: `azure-keyvault` = `keyvault`, `keychain`/`libsecret` = `wallet`, `bw` = `bitwarden`.

**Fallback chain** — local wallet first, Azure Key Vault when the wallet has no entry:

```yaml
      - name: AZURE_CLIENT_SECRET
        sources:
          - source: wallet
            service: homelab
            key: caddy-azure-client-secret
          - source: keyvault
            vault: kv-homelab
            secret: caddy-azure-client-secret
```

## Azure Setup

### Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) installed
- Authenticated: `az login`

### Required RBAC Roles

| Source | Role | Scope |
|--------|------|-------|
| Key Vault | `Key Vault Secrets User` | Key Vault resource |
| APIM Subscription Keys | `API Management Service Reader` | APIM resource |
| APIM Named Values | `API Management Service Reader` | APIM resource |

## Output Formats

### Postman

Generates a [Postman environment](https://learning.postman.com/docs/sending-requests/variables/managing-environments/) JSON file:

```json
{
  "id": "my-project-sit",
  "name": "SIT",
  "values": [
    { "key": "api_key", "value": "...", "enabled": true, "type": "secret" },
    { "key": "baseurl", "value": "https://sit.example.com", "enabled": true, "type": "default" }
  ],
  "_postman_variable_scope": "environment"
}
```

### Bruno

Generates a [Bruno environment](https://docs.usebruno.com/secrets-management/overview) `.bru` file:

```
vars {
  api_key: ...
  baseurl: https://sit.example.com
}
```

### .env (dotenv)

Generates a standard `.env` file:

```
# Generated by secrets-bridge - do not edit
# Environment: sit
API_KEY=...
BASEURL=https://sit.example.com
```

## Adding Providers

Providers are bash scripts in `providers/`. Each provider must implement:

```bash
# Check if the provider CLI is available and authenticated
provider_{name}_check()

# Fetch a secret value (stdout)
provider_{name}_fetch() {
    local source="$1"   # source type (e.g., keyvault, apim-subscription)
    shift
    # remaining args are source-specific
}
```

See `providers/azure.sh` for a complete reference implementation.

## Security Model

- **Secrets never touch disk** (except OS-native keychain storage and generated output files)
- **Keychain namespace isolation** via `SECRETS_SERVICE="secrets-bridge:{project}"`
- **Output files should be gitignored** -- add `*.postman_environment.json`, `.env.*` to `.gitignore`
- **Manifest contains no secret values** -- only references to where secrets live in the cloud
- **Requires active Azure login** -- no service principal credentials stored locally

### Dependencies

| Dependency | Purpose |
|------------|---------|
| [nuvemlabs/secrets](https://github.com/nuvemlabs/secrets) | OS-native keychain access (macOS Keychain, libsecret, Windows Credential Manager) |
| bash | Shell runtime |
| python3 | YAML parsing, JSON generation |
| az CLI | Azure Key Vault and APIM access (`azure` sources only) |
| bw CLI | Bitwarden vault access (`bitwarden` sources only) |

## Development

```bash
for t in tests/test_*.sh; do bash "$t" || echo "FAILED: $t"; done
```

The suites mock `az`, `bw` and `secret-tool`, so no cloud or real store is touched, but they need the
nuvemlabs/secrets library (found as described under Install; CI checks it out and sets `SECRETS_LIB_PATH`).
Packaging sources live in
`packaging/` (AUR `PKGBUILD` + `.SRCINFO`, Homebrew formula).

## License

MIT
