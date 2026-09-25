#!/bin/bash
# Read-only MCP server (plan v3 §14): Release build of arena-suite-mcp, installed to
# ~/.local/bin/arena-suite-mcp. It reads the archive in ~/Library/Application Support/Arena Suite
# read-only and never contacts Arena. Registering it with an MCP client is left to the user.
# Usage: Scripts/build-mcp.sh [--no-install]
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --package-path Packages/ArenaSuiteMCP --product arena-suite-mcp
built="$(swift build -c release --package-path Packages/ArenaSuiteMCP --show-bin-path)/arena-suite-mcp"
"$built" --version

[ "${1:-}" = "--no-install" ] && exit 0

destination="$HOME/.local/bin/arena-suite-mcp"
mkdir -p "$HOME/.local/bin"
staging="$(mktemp "$HOME/.local/bin/.arena-suite-mcp.XXXXXX")"
trap 'rm -f "$staging"' EXIT
cp "$built" "$staging"
chmod 755 "$staging"
mv -f "$staging" "$destination"
trap - EXIT
echo "Installed $destination"
echo "Register it with an MCP client, for example:"
echo "  claude mcp add arena-suite -- \"$destination\""
