#!/usr/bin/env bash
set -euo pipefail

REPO="koltyj/logic-pro-mcp"
BINARY_NAME="LogicProMCP"
INSTALL_DIR="/usr/local/bin"

echo "=== Logic Pro MCP Server — Install ==="
echo ""

# Build from source only when this script is a file inside a logic-pro-mcp checkout.
# Piped through `curl | bash`, BASH_SOURCE is empty and we take the verified download path,
# never a guess based on the current directory.
PROJECT_DIR=""
SCRIPT_PATH="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_PATH" && -f "$SCRIPT_PATH" ]]; then
    PROJECT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)" || exit 1
fi

if [[ -n "$PROJECT_DIR" && -f "$PROJECT_DIR/Package.swift" ]] \
    && grep -q "name: \"$BINARY_NAME\"" "$PROJECT_DIR/Package.swift"; then
    echo "Building from source..."
    cd "$PROJECT_DIR"
    swift build -c release --arch arm64 --arch x86_64 2>&1
    BUILT_BINARY="$PROJECT_DIR/.build/apple/Products/Release/$BINARY_NAME"
    if [[ ! -f "$BUILT_BINARY" ]]; then
        # Fallback for single-arch build
        BUILT_BINARY="$PROJECT_DIR/.build/release/$BINARY_NAME"
    fi
    if [[ ! -f "$BUILT_BINARY" ]]; then
        echo "ERROR: Build failed — binary not found"
        exit 1
    fi
    sudo install -m 0755 "$BUILT_BINARY" "$INSTALL_DIR/$BINARY_NAME"
else
    echo "Downloading latest release..."
    DOWNLOAD_URL="https://github.com/$REPO/releases/latest/download/$BINARY_NAME"
    SUMS_URL="https://github.com/$REPO/releases/latest/download/SHA256SUMS.txt"
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    if ! curl --proto '=https' --tlsv1.2 -fSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_DIR/$BINARY_NAME"; then
        echo "ERROR: Download failed. Check https://github.com/$REPO/releases"
        exit 1
    fi
    if ! curl --proto '=https' --tlsv1.2 -fsSL "$SUMS_URL" -o "$TMP_DIR/SHA256SUMS.txt"; then
        echo "ERROR: Checksum download failed; refusing to install an unverified binary"
        exit 1
    fi
    (cd "$TMP_DIR" && grep "  $BINARY_NAME$" SHA256SUMS.txt | shasum -a 256 -c -)
    sudo install -m 0755 "$TMP_DIR/$BINARY_NAME" "$INSTALL_DIR/$BINARY_NAME"
fi

echo "Installed to $INSTALL_DIR/$BINARY_NAME"

# Check permissions
echo ""
echo "Checking macOS permissions..."
"$INSTALL_DIR/$BINARY_NAME" --check-permissions 2>&1 || true

# Register with Claude Code if available
echo ""
if command -v claude &>/dev/null; then
    echo "Registering with Claude Code..."
    claude mcp add --scope user logic-pro -- "$INSTALL_DIR/$BINARY_NAME" 2>/dev/null && \
        echo "Registered." || echo "Registration skipped (may already exist)."
else
    echo "Register with Claude Code:"
    echo "  claude mcp add --scope user logic-pro -- $INSTALL_DIR/$BINARY_NAME"
fi

echo ""
echo "Claude Desktop config (~/Library/Application Support/Claude/claude_desktop_config.json):"
echo '  {"mcpServers":{"logic-pro":{"command":"'"$INSTALL_DIR/$BINARY_NAME"'","args":[]}}}'
echo ""
echo "Done. Ensure Accessibility + Automation permissions are granted."
