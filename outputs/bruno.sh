#!/usr/bin/env bash
# Bruno environment file output generator for secrets-bridge.
# Generates .bru environment files from secret values.

# Resolve the directory this script lives in
_BRUNO_OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=outputs/private_file.sh
source "$_BRUNO_OUTPUT_DIR/private_file.sh"

# Generate a Bruno environment .bru file.
#
# Arguments:
#   $1 - project name (unused in Bruno format but kept for API consistency)
#   $2 - environment name
#   $3 - output file path
#   $4 - JSON array of secret entries: [{"name":"x","value":"y"}, ...]
#
# Output format:
#   vars {
#     key1: value1
#     key2: value2
#   }
output_bruno_generate() {
    local project="$1" environment="$2" output_file="$3" secrets_json="$4"

    [[ -z "$project" ]] && { echo "Error: project name required" >&2; return 1; }
    [[ -z "$environment" ]] && { echo "Error: environment name required" >&2; return 1; }
    [[ -z "$output_file" ]] && { echo "Error: output file path required" >&2; return 1; }
    [[ -z "$secrets_json" ]] && { echo "Error: secrets JSON required" >&2; return 1; }

    # Ensure output directory exists
    local output_dir
    output_dir="$(dirname "$output_file")"
    mkdir -p "$output_dir"
    output_prepare_private_file "$output_file" || return 1

    # Extract key-value pairs from JSON and write .bru format. The JSON goes
    # in on stdin: argv is visible to every local account (ps, /proc).
    {
        echo "vars {"
        printf '%s' "$secrets_json" | python3 -c "
import json, sys
secrets = json.load(sys.stdin)
for entry in secrets:
    name = entry.get('name', '')
    value = entry.get('value', '')
    print(f'  {name}: {value}')
"
        echo "}"
    } > "$output_file"
}
