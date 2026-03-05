#!/bin/bash
# install.sh - Install nuvemlabs/secrets-bridge to ~/.local/lib/secrets-bridge/
set -euo pipefail

INSTALL_DIR="${SECRETS_BRIDGE_INSTALL_DIR:-$HOME/.local/lib/secrets-bridge}"
BIN_DIR="$HOME/.local/bin"
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
#   Dependency check: nuvemlabs/secrets
# ---------------------------------------------------------------------------

echo "[secrets-bridge] Checking dependencies..."

if [[ ! -f "$HOME/.local/lib/secrets/secrets.sh" ]]; then
    echo "" >&2
    echo "Error: nuvemlabs/secrets is not installed." >&2
    echo "" >&2
    echo "secrets-bridge requires the secrets library. Install it first:" >&2
    echo "  git clone https://github.com/nuvemlabs/secrets.git" >&2
    echo "  cd secrets && bash install.sh" >&2
    echo "" >&2
    exit 1
fi

echo "[secrets-bridge] Found nuvemlabs/secrets at ~/.local/lib/secrets/"

# ---------------------------------------------------------------------------
#   Install files
# ---------------------------------------------------------------------------

echo "[secrets-bridge] Installing to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/providers"
mkdir -p "$INSTALL_DIR/outputs"
mkdir -p "$INSTALL_DIR/lib"

cp "$SOURCE_DIR/secrets-bridge.sh" "$INSTALL_DIR/"
cp "$SOURCE_DIR/providers/"*.sh "$INSTALL_DIR/providers/"
cp "$SOURCE_DIR/outputs/"*.sh "$INSTALL_DIR/outputs/"
cp "$SOURCE_DIR/outputs/"*.py "$INSTALL_DIR/outputs/"
cp "$SOURCE_DIR/lib/"*.py "$INSTALL_DIR/lib/"

chmod +x "$INSTALL_DIR/secrets-bridge.sh"

# ---------------------------------------------------------------------------
#   Create symlink in PATH
# ---------------------------------------------------------------------------

mkdir -p "$BIN_DIR"

# Remove stale symlink if it exists
if [[ -L "$BIN_DIR/secrets-bridge" ]]; then
    rm "$BIN_DIR/secrets-bridge"
fi

ln -s "$INSTALL_DIR/secrets-bridge.sh" "$BIN_DIR/secrets-bridge"

echo "[secrets-bridge] Installed successfully"
echo ""
echo "Symlink: $BIN_DIR/secrets-bridge -> $INSTALL_DIR/secrets-bridge.sh"
echo ""
echo "Ensure ~/.local/bin is in your PATH:"
echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
