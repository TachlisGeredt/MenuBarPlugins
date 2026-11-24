#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos13.0"
MODULE_CACHE="/tmp/mbp-module-cache"
mkdir -p "$MODULE_CACHE"

APP_DIR="$ROOT_DIR/MenuBarPlugins.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
PLUGINS_DIR="$ROOT_DIR/Plugins"

echo "==> Preparing $APP_DIR (target: $TARGET)..."
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$PLUGINS_DIR"

echo "==> Building MenuBarPluginKit.dylib (Library Evolution enabled)..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -parse-as-library \
    -enable-library-evolution \
    -module-name MenuBarPluginKit \
    -emit-module \
    -emit-module-path "$FRAMEWORKS_DIR/MenuBarPluginKit.swiftmodule" \
    -emit-module-interface-path "$FRAMEWORKS_DIR/MenuBarPluginKit.swiftinterface" \
    -emit-library \
    -Xlinker -install_name -Xlinker "@rpath/libMenuBarPluginKit.dylib" \
    -o "$FRAMEWORKS_DIR/libMenuBarPluginKit.dylib" \
    "$ROOT_DIR"/Sources/MenuBarPluginKit/*.swift

echo "==> Building MenuBarHost..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -I "$FRAMEWORKS_DIR" \
    -L "$FRAMEWORKS_DIR" \
    -lMenuBarPluginKit \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -o "$MACOS_DIR/MenuBarHost" \
    "$ROOT_DIR"/Sources/MenuBarHost/*.swift

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MenuBarHost</string>
    <key>CFBundleIdentifier</key>
    <string>com.menubarplugins.host</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MenuBarPlugins</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Building mbp CLI..."
swiftc \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -module-cache-path "$MODULE_CACHE" \
    -O \
    -I "$FRAMEWORKS_DIR" \
    -L "$FRAMEWORKS_DIR" \
    -lMenuBarPluginKit \
    -Xlinker -rpath -Xlinker "@executable_path/MenuBarPlugins.app/Contents/Frameworks" \
    -o "$ROOT_DIR/mbp" \
    "$ROOT_DIR"/Sources/mbp-cli/main.swift

echo "==> Signing binaries (ad-hoc)..."
codesign --force --sign - "$FRAMEWORKS_DIR/libMenuBarPluginKit.dylib" 2>/dev/null || true
codesign --force --sign - "$ROOT_DIR/mbp" 2>/dev/null || true
codesign --force --sign - --deep "$APP_DIR" 2>/dev/null || true

echo "==> Build complete!"
echo "    App:     $APP_DIR"
echo "    Plugins: $PLUGINS_DIR"
echo "    CLI:     $ROOT_DIR/mbp"
