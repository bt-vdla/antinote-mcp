#!/bin/zsh
# Builds build/AntinoteMCP.app: a sandboxed, ad-hoc-signed app bundle whose executable is the MCP server.
# Requires Xcode Command Line Tools (swiftc). No other dependencies.
set -euo pipefail
cd "${0:A:h}"

APP=build/AntinoteMCP.app
ARCH=$(uname -m)
mkdir -p "$APP/Contents/MacOS"
cp Support/Info.plist "$APP/Contents/Info.plist"

xcrun swiftc -O -target "${ARCH}-apple-macos14.0" \
  Sources/AntinoteMCP/*.swift \
  -o "$APP/Contents/MacOS/antinote-mcp"

xattr -cr "$APP"
codesign --force --sign - --entitlements Support/entitlements.plist "$APP"

echo "Built $PWD/$APP"
echo "Executable: $PWD/$APP/Contents/MacOS/antinote-mcp"
echo "First run (and after every rebuild): $PWD/$APP/Contents/MacOS/antinote-mcp grant"
