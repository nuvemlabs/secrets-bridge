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

## Quick Start

```bash
# 1. Install nuvemlabs/secrets (dependency)
git clone https://github.com/nuvemlabs/secrets.git
cd secrets && bash install.sh && cd ..

# 2. Install secrets-bridge
git clone https://github.com/nuvemlabs/secrets-bridge.git
cd secrets-bridge && bash install.sh

# 3. Create a manifest in your project
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

# 4. Sync (fetch + generate)
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
| `source` | for cloud secrets | `keyvault`, `apim-subscription`, or `apim-named-value` |
| `value` | for static values | Literal value (not fetched from cloud) |
| `secret` | no | `false` marks as non-secret (type=default in Postman). Default: `true` |

**Key Vault fields:** `vault`, `secret`

**APIM subscription fields:** `resource_group`, `service`, `subscription_id`, `key` (primary/secondary)

**APIM named value fields:** `resource_group`, `service`, `named_value_id`

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
| az CLI | Azure Key Vault and APIM access |

## License

MIT
