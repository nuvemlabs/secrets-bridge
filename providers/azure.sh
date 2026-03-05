#!/usr/bin/env bash
# Azure provider for secrets-bridge
# Fetches secrets from Azure Key Vault, APIM subscriptions, and APIM named values.

# Check az CLI is available and logged in
provider_azure_check() {
    if ! command -v az &>/dev/null; then
        echo "Error: Azure CLI (az) is not installed" >&2
        return 1
    fi
    if ! az account show &>/dev/null 2>&1; then
        echo "Error: Not logged in to Azure. Run 'az login' first." >&2
        return 1
    fi
}

# Set the Azure subscription context
provider_azure_set_subscription() {
    local subscription="$1"
    [[ -z "$subscription" ]] && { echo "Error: subscription name required" >&2; return 1; }
    az account set --subscription "$subscription" 2>/dev/null || {
        echo "Error: Failed to set subscription '$subscription'" >&2
        return 1
    }
}

# Fetch from Key Vault
provider_azure_fetch_keyvault() {
    local vault="$1" secret_name="$2"
    [[ -z "$vault" || -z "$secret_name" ]] && { echo "Error: vault and secret name required" >&2; return 1; }
    az keyvault secret show --vault-name "$vault" --name "$secret_name" --query "value" --output tsv 2>/dev/null
}

# Fetch APIM subscription key via REST API
provider_azure_fetch_apim_subscription() {
    local rg="$1" service="$2" sub_id="$3" key_type="${4:-primary}"
    [[ -z "$rg" || -z "$service" || -z "$sub_id" ]] && { echo "Error: resource_group, service, and subscription_id required" >&2; return 1; }
    local azure_sub_id
    azure_sub_id=$(az account show --query id -o tsv)
    az rest --method post \
        --uri "/subscriptions/${azure_sub_id}/resourceGroups/${rg}/providers/Microsoft.ApiManagement/service/${service}/subscriptions/${sub_id}/listSecrets?api-version=2022-08-01" \
        --query "${key_type}Key" --output tsv 2>/dev/null
}

# Fetch APIM named value
provider_azure_fetch_apim_named_value() {
    local rg="$1" service="$2" nv_id="$3"
    [[ -z "$rg" || -z "$service" || -z "$nv_id" ]] && { echo "Error: resource_group, service, and named_value_id required" >&2; return 1; }
    az apim nv show-secret --resource-group "$rg" --service-name "$service" --named-value-id "$nv_id" --query "value" --output tsv 2>/dev/null
}

# Dispatch fetch based on source type
provider_azure_fetch() {
    local source="$1"
    shift
    case "$source" in
        keyvault)          provider_azure_fetch_keyvault "$@" ;;
        apim-subscription) provider_azure_fetch_apim_subscription "$@" ;;
        apim-named-value)  provider_azure_fetch_apim_named_value "$@" ;;
        *) echo "Error: Unknown Azure source type: $source" >&2; return 1 ;;
    esac
}
