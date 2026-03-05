#!/usr/bin/env bash
# Bruno environment file output generator for secrets-bridge.
# Generates .bru environment files from secret values.

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

    # Extract key-value pairs from JSON and write .bru format
    {
        echo "vars {"
        python3 -c "
import json, sys
secrets = json.loads(sys.argv[1])
for entry in secrets:
    name = entry.get('name', '')
    value = entry.get('value', '')
    print(f'  {name}: {value}')
" "$secrets_json"
        echo "}"
    } > "$output_file"
}
