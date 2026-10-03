#!/usr/bin/env bash
# test_install.sh - install.sh layouts and how an installed CLI finds the
# nuvemlabs/secrets library.
#
# Hermetic: HOME, PATH entries and every install target live in a temp dir,
# and the library is a stub, so no real store or ~/.local is touched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

PASS=0
FAIL=0

# Lookup cases below control the library location themselves; an inherited
# override (CI sets one) would win over every one of them
unset SECRETS_LIB_PATH

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (missing '$needle')"
        echo "    output: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if ! grep -qF -- "$needle" <<<"$haystack"; then
        echo "  PASS: $test_name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $test_name (unexpected '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# A stub nuvemlabs/secrets install in <prefix>: the library marks which copy
# was sourced, and secrets-doctor sits in <prefix>/bin as in every real layout.
make_secrets_prefix() {
    local prefix="$1" tag="$2"
    mkdir -p "$prefix/lib/secrets" "$prefix/bin"
    printf 'SECRETS_STUB_TAG=%s\nSECRETS_SERVICE=${SECRETS_SERVICE:-secrets}\n' "$tag" \
        > "$prefix/lib/secrets/secrets.sh"
    printf '#!/bin/bash\nexit 0\n' > "$prefix/bin/secrets-doctor"
    chmod +x "$prefix/bin/secrets-doctor"
}

echo "=== install.sh + library lookup ==="

echo "-- default: per-user ~/.local --"
home="$TMP/home"
make_secrets_prefix "$home/.local" local
HOME="$home" bash "$INSTALLER" >/dev/null
[[ -L "$home/.local/bin/secrets-bridge" ]] && echo "  PASS: default: bin symlink" && PASS=$((PASS + 1)) \
    || { echo "  FAIL: default: bin symlink missing"; FAIL=$((FAIL + 1)); }
out="$(HOME="$home" "$home/.local/bin/secrets-bridge" --version 2>&1)"
assert_contains "default: --version runs" "secrets-bridge v" "$out"

echo "-- PREFIX + DESTDIR: packaged layout --"
stage="$TMP/stage"
pkg_home="$TMP/pkg-home"
out="$(HOME="$pkg_home" PREFIX=/usr DESTDIR="$stage" bash "$INSTALLER")"
assert_eq "packaged: library dir staged" "yes" \
    "$([[ -f "$stage/usr/lib/secrets-bridge/secrets-bridge.sh" ]] && echo yes || echo no)"
assert_eq "packaged: bin link targets the runtime path" "/usr/lib/secrets-bridge/secrets-bridge.sh" \
    "$(readlink "$stage/usr/bin/secrets-bridge")"
assert_eq "packaged: nothing written to ~/.local" "no" "$([[ -e "$pkg_home/.local" ]] && echo yes || echo no)"
assert_not_contains "packaged: no dependency error at build time" "is not installed" "$out"

echo "-- relative symlink chain (Homebrew style) --"
cellar="$TMP/brew/Cellar/secrets-bridge/9.9.9"
PREFIX="$cellar" bash "$INSTALLER" >/dev/null
mkdir -p "$TMP/brew/bin"
ln -s "../Cellar/secrets-bridge/9.9.9/bin/secrets-bridge" "$TMP/brew/bin/secrets-bridge"
make_secrets_prefix "$TMP/brew/Cellar/secrets/1.0" brew
ln -s "../Cellar/secrets/1.0/bin/secrets-doctor" "$TMP/brew/bin/secrets-doctor"
empty_home="$TMP/empty-home"
mkdir -p "$empty_home"
out="$(cd "$TMP" && HOME="$empty_home" PATH="$TMP/brew/bin:/usr/bin:/bin" \
    SECRETS_BRIDGE_DEBUG_LIB=1 secrets-bridge --version 2>&1)"
assert_contains "brew: CLI runs through relative links" "secrets-bridge v" "$out"
assert_contains "brew: library found via secrets-doctor on PATH" "secrets lib: $TMP/brew/Cellar/secrets/1.0/lib/secrets/secrets.sh" "$out"

echo "-- SECRETS_LIB_PATH wins over ~/.local --"
make_secrets_prefix "$TMP/override" override
out="$(HOME="$home" SECRETS_LIB_PATH="$TMP/override/lib/secrets/secrets.sh" SECRETS_BRIDGE_DEBUG_LIB=1 \
    "$home/.local/bin/secrets-bridge" --version 2>&1)"
assert_contains "override: explicit path used" "secrets lib: $TMP/override/lib/secrets/secrets.sh" "$out"

echo "-- no library anywhere --"
out="$(cd "$TMP" && HOME="$empty_home" PATH="$TMP/brew/bin-none:/usr/bin:/bin" \
    "$cellar/bin/secrets-bridge" --version 2>&1 || true)"
assert_contains "missing library: clear error" "nuvemlabs/secrets library not found" "$out"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
