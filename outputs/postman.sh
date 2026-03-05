#!/usr/bin/env bash
# Postman environment JSON output generator for secrets-bridge.
# Generates Postman-compatible environment files from secret values.

# Resolve the directory this script lives in
_POSTMAN_OUTPUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Generate a Postman environment JSON file.
#
# Arguments:
#   $1 - project name
#   $2 - environment name (lowercase)
#   $3 - output file path
#   $4 - JSON array of secret entries: [{"name":"x","value":"y","secret":true}, ...]
#
# The secret entries JSON should have the fields:
#   name   - variable name (key in Postman)
#   value  - the resolved secret value
#   secret - boolean, true for secret type, false for default type
output_postman_generate() {
    local project="$1" environment="$2" output_file="$3" secrets_json="$4"

    [[ -z "$project" ]] && { echo "Error: project name required" >&2; return 1; }
    [[ -z "$environment" ]] && { echo "Error: environment name required" >&2; return 1; }
    [[ -z "$output_file" ]] && { echo "Error: output file path required" >&2; return 1; }
    [[ -z "$secrets_json" ]] && { echo "Error: secrets JSON required" >&2; return 1; }

    # Ensure output directory exists
    local output_dir
    output_dir="$(dirname "$output_file")"
    mkdir -p "$output_dir"

    # Build the input JSON for the template
    local input_json
    input_json=$(python3 -c "
import json, sys
project = sys.argv[1]
environment = sys.argv[2]
secrets = json.loads(sys.argv[3])
print(json.dumps({
    'project': project,
    'environment': environment,
    'secrets': secrets
}))
" "$project" "$environment" "$secrets_json")

    # Pipe through the template generator
    echo "$input_json" | python3 "$_POSTMAN_OUTPUT_DIR/postman_template.py" > "$output_file"
}
