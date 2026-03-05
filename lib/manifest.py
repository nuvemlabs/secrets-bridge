#!/usr/bin/env python3
"""
YAML manifest parser for secrets-bridge.

Parses a secrets-bridge manifest YAML file and outputs JSON to stdout.
Uses PyYAML if available, otherwise falls back to a built-in parser
that handles the specific YAML subset needed for manifests.

Usage:
    python3 manifest.py <manifest-path> project            # project info
    python3 manifest.py <manifest-path> secrets <env>       # secret definitions
    python3 manifest.py <manifest-path> outputs <env>       # output definitions
    python3 manifest.py <manifest-path> envs                # environment names
    python3 manifest.py <manifest-path> azure-config <env>  # azure config
"""

import json
import sys
import os

# ---------------------------------------------------------------------------
# Try PyYAML first, fall back to built-in parser
# ---------------------------------------------------------------------------

_USE_PYYAML = False

try:
    import yaml as _yaml
    _USE_PYYAML = True
except ImportError:
    pass


# ---------------------------------------------------------------------------
# Built-in YAML parser (handles the manifest subset)
# ---------------------------------------------------------------------------

class _YamlParseError(Exception):
    pass


def _builtin_parse(text):
    """Parse a YAML string into a Python dict.

    Supports:
      - Key: value pairs
      - Indentation-based nesting (spaces only)
      - List items (lines starting with '- ')
      - Quoted and unquoted string values
      - Boolean values (true/false)
      - Comments (# ...) and blank lines
      - Multi-level nesting
    """
    lines = text.splitlines()
    return _parse_block(lines, 0, 0)[0]


def _strip_comment(line):
    """Remove inline comments, respecting quoted strings."""
    in_single = False
    in_double = False
    for i, ch in enumerate(line):
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == '#' and not in_single and not in_double:
            return line[:i].rstrip()
    return line


def _indent_of(line):
    """Return the number of leading spaces."""
    return len(line) - len(line.lstrip(' '))


def _parse_scalar(value):
    """Convert a scalar string to the appropriate Python type."""
    if value == '':
        return ''
    # Strip quotes
    if (value.startswith('"') and value.endswith('"')) or \
       (value.startswith("'") and value.endswith("'")):
        return value[1:-1]
    # Booleans
    lower = value.lower()
    if lower == 'true':
        return True
    if lower == 'false':
        return False
    # Null
    if lower in ('null', '~'):
        return None
    # Numbers
    try:
        return int(value)
    except ValueError:
        pass
    try:
        return float(value)
    except ValueError:
        pass
    return value


def _parse_block(lines, start, base_indent):
    """Parse a block of YAML lines into a dict or list.

    Returns (parsed_object, next_line_index).
    """
    if start >= len(lines):
        return {}, start

    # Skip blank/comment lines to find the first meaningful line
    idx = start
    while idx < len(lines):
        stripped = lines[idx].strip()
        if stripped == '' or stripped.startswith('#'):
            idx += 1
            continue
        break

    if idx >= len(lines):
        return {}, idx

    first_line = lines[idx]
    first_indent = _indent_of(first_line)
    first_content = first_line.strip()

    # Determine if this block is a list or a mapping
    if first_content.startswith('- '):
        return _parse_list(lines, idx, first_indent)
    else:
        return _parse_mapping(lines, idx, first_indent)


def _parse_mapping(lines, start, base_indent):
    """Parse a YAML mapping (dict)."""
    result = {}
    idx = start

    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()

        # Skip blank lines and comments
        if stripped == '' or stripped.startswith('#'):
            idx += 1
            continue

        current_indent = _indent_of(line)

        # If we've dedented past our base, this block is done
        if current_indent < base_indent:
            break

        # If we're at our level, parse a key-value pair
        if current_indent == base_indent:
            # Must be a key: value line
            if ':' not in stripped:
                break

            colon_pos = stripped.index(':')
            key = stripped[:colon_pos].strip()
            rest = stripped[colon_pos + 1:].strip()
            rest = _strip_comment(rest)

            if rest:
                # Inline value
                result[key] = _parse_scalar(rest)
                idx += 1
            else:
                # Block value - look at next non-blank line
                next_idx = idx + 1
                while next_idx < len(lines):
                    next_stripped = lines[next_idx].strip()
                    if next_stripped == '' or next_stripped.startswith('#'):
                        next_idx += 1
                        continue
                    break

                if next_idx >= len(lines):
                    result[key] = None
                    idx = next_idx
                else:
                    next_indent = _indent_of(lines[next_idx])
                    if next_indent > base_indent:
                        value, idx = _parse_block(lines, next_idx, next_indent)
                        result[key] = value
                    else:
                        result[key] = None
                        idx = next_idx
        else:
            # Indented more than expected - skip
            idx += 1

    return result, idx


def _parse_list(lines, start, base_indent):
    """Parse a YAML list."""
    result = []
    idx = start

    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()

        # Skip blank lines and comments
        if stripped == '' or stripped.startswith('#'):
            idx += 1
            continue

        current_indent = _indent_of(line)

        # If we've dedented past our base, this block is done
        if current_indent < base_indent:
            break

        if current_indent == base_indent and stripped.startswith('- '):
            # Start of a list item
            item_content = stripped[2:].strip()
            item_content = _strip_comment(item_content)

            if ':' in item_content:
                # This is a mapping item: - key: value
                colon_pos = item_content.index(':')
                key = item_content[:colon_pos].strip()
                rest = item_content[colon_pos + 1:].strip()
                rest = _strip_comment(rest)

                # Collect the rest of this item's mapping
                item_dict = {}
                if rest:
                    item_dict[key] = _parse_scalar(rest)
                else:
                    # Block value under this key
                    next_idx = idx + 1
                    while next_idx < len(lines):
                        ns = lines[next_idx].strip()
                        if ns == '' or ns.startswith('#'):
                            next_idx += 1
                            continue
                        break
                    if next_idx < len(lines) and _indent_of(lines[next_idx]) > base_indent:
                        value, next_idx = _parse_block(lines, next_idx, _indent_of(lines[next_idx]))
                        item_dict[key] = value
                    else:
                        item_dict[key] = None

                # Parse continuation lines at deeper indent
                idx += 1
                child_indent = base_indent + 2  # Expected indent for continuation
                while idx < len(lines):
                    cline = lines[idx]
                    cs = cline.strip()
                    if cs == '' or cs.startswith('#'):
                        idx += 1
                        continue
                    cindent = _indent_of(cline)
                    if cindent <= base_indent:
                        break
                    # Parse as part of this mapping item
                    if ':' in cs and not cs.startswith('- '):
                        ccolon = cs.index(':')
                        ckey = cs[:ccolon].strip()
                        crest = cs[ccolon + 1:].strip()
                        crest = _strip_comment(crest)
                        if crest:
                            item_dict[ckey] = _parse_scalar(crest)
                            idx += 1
                        else:
                            next_idx = idx + 1
                            while next_idx < len(lines):
                                ns = lines[next_idx].strip()
                                if ns == '' or ns.startswith('#'):
                                    next_idx += 1
                                    continue
                                break
                            if next_idx < len(lines) and _indent_of(lines[next_idx]) > cindent:
                                value, idx = _parse_block(lines, next_idx, _indent_of(lines[next_idx]))
                                item_dict[ckey] = value
                            else:
                                item_dict[ckey] = None
                                idx = next_idx
                    else:
                        idx += 1

                result.append(item_dict)
            else:
                # Simple scalar list item
                result.append(_parse_scalar(item_content))
                idx += 1
        elif current_indent > base_indent:
            # Continuation of previous list item - skip (already handled)
            idx += 1
        else:
            break

    return result, idx


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def load_manifest(path):
    """Load and parse a YAML manifest file."""
    if not os.path.isfile(path):
        print(f"Error: File not found: {path}", file=sys.stderr)
        sys.exit(1)

    with open(path, 'r') as f:
        text = f.read()

    if _USE_PYYAML:
        return _yaml.safe_load(text)
    else:
        return _builtin_parse(text)


def cmd_project(manifest):
    """Return project info as JSON."""
    result = {
        "project": manifest.get("project", ""),
        "default_provider": manifest.get("default_provider", ""),
    }
    return json.dumps(result)


def cmd_envs(manifest):
    """Return list of environment names."""
    envs = manifest.get("environments", {})
    if envs is None:
        return json.dumps([])
    return json.dumps(sorted(envs.keys()))


def cmd_secrets(manifest, env):
    """Return secret definitions for an environment."""
    envs = manifest.get("environments", {})
    if envs is None or env not in envs:
        print(f"Error: Environment '{env}' not found", file=sys.stderr)
        sys.exit(1)
    env_config = envs[env]
    secrets = env_config.get("secrets", [])
    if secrets is None:
        secrets = []
    return json.dumps(secrets)


def cmd_outputs(manifest, env):
    """Return output definitions for an environment."""
    envs = manifest.get("environments", {})
    if envs is None or env not in envs:
        print(f"Error: Environment '{env}' not found", file=sys.stderr)
        sys.exit(1)
    env_config = envs[env]
    outputs = env_config.get("outputs", [])
    if outputs is None:
        outputs = []
    return json.dumps(outputs)


def cmd_azure_config(manifest, env):
    """Return Azure configuration for an environment."""
    envs = manifest.get("environments", {})
    if envs is None or env not in envs:
        print(f"Error: Environment '{env}' not found", file=sys.stderr)
        sys.exit(1)
    env_config = envs[env]
    azure = env_config.get("azure", {})
    if azure is None:
        azure = {}
    return json.dumps(azure)


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 3:
        print("Usage: manifest.py <manifest-path> <command> [args...]", file=sys.stderr)
        sys.exit(1)

    manifest_path = sys.argv[1]
    command = sys.argv[2]

    manifest = load_manifest(manifest_path)

    if command == "project":
        print(cmd_project(manifest))
    elif command == "envs":
        print(cmd_envs(manifest))
    elif command == "secrets":
        if len(sys.argv) < 4:
            print("Usage: manifest.py <path> secrets <env>", file=sys.stderr)
            sys.exit(1)
        print(cmd_secrets(manifest, sys.argv[3]))
    elif command == "outputs":
        if len(sys.argv) < 4:
            print("Usage: manifest.py <path> outputs <env>", file=sys.stderr)
            sys.exit(1)
        print(cmd_outputs(manifest, sys.argv[3]))
    elif command == "azure-config":
        if len(sys.argv) < 4:
            print("Usage: manifest.py <path> azure-config <env>", file=sys.stderr)
            sys.exit(1)
        print(cmd_azure_config(manifest, sys.argv[3]))
    else:
        print(f"Error: Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
