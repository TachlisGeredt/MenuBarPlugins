#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
FRAMEWORKS_DIR="$ROOT_DIR/MenuBarPlugins.app/Contents/Frameworks"

if [ ! -f "$FRAMEWORKS_DIR/libMenuBarPluginKit.dylib" ]; then
    "$ROOT_DIR/scripts/build-app.sh"
fi

RUNNER_BIN="/tmp/menubarplugins-test-runner"
FIXTURE_DYLIB="/tmp/libFixturePlugin.dylib"
MODULE_CACHE="/tmp/mbp-module-cache"
mkdir -p "$MODULE_CACHE"

trap 'rm -f "$RUNNER_BIN" "$FIXTURE_DYLIB"' EXIT

echo "==> Building FixturePlugin contract dylib..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -parse-as-library \
    -emit-library \
    -I "$FRAMEWORKS_DIR" \
    -L "$FRAMEWORKS_DIR" \
    -lMenuBarPluginKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS_DIR" \
    -o "$FIXTURE_DYLIB" \
    "$ROOT_DIR/Tests/FixturePlugin/FixturePlugin.swift"

echo "==> Building and running TestRunner..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -I "$FRAMEWORKS_DIR" \
    -L "$FRAMEWORKS_DIR" \
    -lMenuBarPluginKit \
    -Xlinker -rpath -Xlinker "$FRAMEWORKS_DIR" \
    -o "$RUNNER_BIN" \
    "$ROOT_DIR/Tests/TestRunner/main.swift"

"$RUNNER_BIN" "$FIXTURE_DYLIB"
