#!/usr/bin/env python3
"""
Postman environment JSON generator for secrets-bridge.

Reads JSON from stdin with the structure:
{
    "project": "td-postman",
    "environment": "sit",
    "secrets": [
        {"name": "client_secret_td", "value": "abc123", "secret": true},
        {"name": "baseurl", "value": "https://example.com", "secret": false}
    ]
}

Outputs a Postman environment JSON file to stdout.
"""

import json
import sys


def generate_postman_env(data):
    """Generate Postman environment JSON from input data."""
    project = data.get("project", "")
    environment = data.get("environment", "")
    secrets = data.get("secrets", [])

    values = []
    for entry in secrets:
        name = entry.get("name", "")
        value = entry.get("value", "")
        is_secret = entry.get("secret", True)

        values.append({
            "key": name,
            "value": value,
            "enabled": True,
            "type": "secret" if is_secret else "default",
        })

    env_doc = {
        "id": f"{project}-{environment}",
        "name": environment.upper(),
        "values": values,
        "_postman_variable_scope": "environment",
    }

    return json.dumps(env_doc, indent=2)


def main():
    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
        sys.exit(1)

    print(generate_postman_env(data))


if __name__ == "__main__":
    main()
