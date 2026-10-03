#!/bin/bash
# install.sh - Install nuvemlabs/secrets-bridge
#
# Per-user (default):  ~/.local/lib/secrets-bridge + ~/.local/bin/secrets-bridge
# Packaged:            PREFIX=/usr DESTDIR="$pkgdir" ./install.sh
#                      -> $DESTDIR$PREFIX/lib/secrets-bridge + $DESTDIR$PREFIX/bin
# SECRETS_BRIDGE_INSTALL_DIR / SECRETS_BRIDGE_BIN_DIR override either layout.
set -euo pipefail

SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${PREFIX:-}" ]]; then
    DEFAULT_LIB_DIR="$PREFIX/lib/secrets-bridge"
    DEFAULT_BIN_DIR="$PREFIX/bin"
else
    DEFAULT_LIB_DIR="$HOME/.local/lib/secrets-bridge"
    DEFAULT_BIN_DIR="$HOME/.local/bin"
fi

# Final (runtime) locations; DESTDIR only stages them for a package build
INSTALL_DIR="${SECRETS_BRIDGE_INSTALL_DIR:-$DEFAULT_LIB_DIR}"
BIN_DIR="${SECRETS_BRIDGE_BIN_DIR:-$DEFAULT_BIN_DIR}"
DESTDIR="${DESTDIR:-}"

# ---------------------------------------------------------------------------
#   Dependency check: nuvemlabs/secrets (per-user installs only; a package
#   manager declares the dependency itself)
# ---------------------------------------------------------------------------

if [[ -z "$DESTDIR" && -z "${PREFIX:-}" ]]; then
    echo "[secrets-bridge] Checking dependencies..."
    if [[ ! -f "$HOME/.local/lib/secrets/secrets.sh" ]] && ! command -v secrets-doctor &>/dev/null; then
        echo "" >&2
        echo "Error: nuvemlabs/secrets is not installed." >&2
        echo "" >&2
        echo "secrets-bridge requires the secrets library. Install it first:" >&2
        echo "  brew install nuvemlabs/tap/secrets" >&2
        echo "  or: git clone https://github.com/nuvemlabs/secrets.git && cd secrets && bash install.sh" >&2
        echo "" >&2
        exit 1
    fi
    echo "[secrets-bridge] Found nuvemlabs/secrets"
fi

# ---------------------------------------------------------------------------
#   Install files
# ---------------------------------------------------------------------------

echo "[secrets-bridge] Installing to $DESTDIR$INSTALL_DIR"
install -d "$DESTDIR$INSTALL_DIR/providers" "$DESTDIR$INSTALL_DIR/outputs" "$DESTDIR$INSTALL_DIR/lib"
install -m 755 "$SOURCE_DIR/secrets-bridge.sh" "$DESTDIR$INSTALL_DIR/"
install -m 644 "$SOURCE_DIR/providers/"*.sh "$DESTDIR$INSTALL_DIR/providers/"
install -m 644 "$SOURCE_DIR/outputs/"*.sh "$SOURCE_DIR/outputs/"*.py "$DESTDIR$INSTALL_DIR/outputs/"
install -m 644 "$SOURCE_DIR/lib/"*.py "$DESTDIR$INSTALL_DIR/lib/"

# ---------------------------------------------------------------------------
#   Command on PATH: a symlink to the runtime path (never the staging dir)
# ---------------------------------------------------------------------------

install -d "$DESTDIR$BIN_DIR"
ln -sfn "$INSTALL_DIR/secrets-bridge.sh" "$DESTDIR$BIN_DIR/secrets-bridge"

echo "[secrets-bridge] Installed successfully"
echo ""
echo "Symlink: $BIN_DIR/secrets-bridge -> $INSTALL_DIR/secrets-bridge.sh"
echo ""
echo "Ensure $BIN_DIR is in your PATH."
