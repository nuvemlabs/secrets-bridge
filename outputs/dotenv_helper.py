#!/usr/bin/env python3
"""
Dotenv helper for secrets-bridge.

Takes a JSON array of secret entries on stdin and outputs dotenv key=value lines.
Values containing spaces, quotes, or shell special characters are double-quoted.

Input: JSON array [{"name": "x", "value": "y"}, ...]
Output: KEY=value lines (one per entry)
"""

import json
import re
import sys

# Characters that require the value to be double-quoted in a .env file
_NEEDS_QUOTING = re.compile(r'[\s"\'\\$`!#&|;(){}]')


def generate_dotenv_lines(secrets):
    """Generate dotenv lines from a list of secret entries."""
    lines = []
    for entry in secrets:
        name = entry.get("name", "")
        value = str(entry.get("value", ""))
        # Convert name to uppercase with underscores (dotenv convention)
        env_key = name.upper().replace("-", "_")
        if _NEEDS_QUOTING.search(value):
            # Escape backslashes and double quotes inside the value
            escaped = value.replace("\\", "\\\\").replace('"', '\\"')
            lines.append(f'{env_key}="{escaped}"')
        else:
            lines.append(f"{env_key}={value}")
    return lines


def main():
    try:
        secrets = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON input: {e}", file=sys.stderr)
        sys.exit(1)

    for line in generate_dotenv_lines(secrets):
        print(line)


if __name__ == "__main__":
    main()
