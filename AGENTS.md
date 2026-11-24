# AGENTS.md — AI Guide for Building MenuBarPlugins

This document tells AI coding agents how to build, compile, install, and test plugins for **MenuBarPlugins** cleanly and with minimal CPU/RAM usage.

---

## Architecture Summary

- **Host App**: `MenuBarPlugins.app` (pure Swift + AppKit, `LSUIElement = true`, macOS 13+).
  - Shows a fallback puzzle-piece icon only when 0 plugins are active and `persistentIcon` is `true` (default).
  - Automatically appends a lazy **Manage Icons ▸** submenu to the bottom of every active plugin's menu (plugins do not need to add host controls themselves).
- **Shared SDK**: `MenuBarPluginKit` (`MenuBarPlugins.app/Contents/Frameworks/libMenuBarPluginKit.dylib` + `MenuBarPluginKit.swiftmodule` + `MenuBarPluginKit.swiftinterface`), compiled with `-enable-library-evolution` for binary compatibility across additive updates.
- **Portable Plugins Directory**: `Plugins/<PluginName>/` right next to `MenuBarPlugins.app`.
  - Every plugin is **100% self-contained** in its own subfolder:
    - `manifest.json` (required)
    - `lib<PluginName>.dylib` (required)
    - `Data/` (optional, created lazily via `context.ensureDataDirectory()` only if the plugin persists state)
  - Never write files to `~/Library/Application Support/` or anywhere outside the plugin's own folder.

---

## Plugin Contract (`MenuBarPluginKit`)

Every plugin must:
1. Import `MenuBarPluginKit` (and `AppKit` / `Foundation`).
2. Implement `@objc public protocol MenuBarPlugin: AnyObject` on an `NSObject` subclass.
3. Export a C-ABI factory symbol named `mbp_create_plugin`:

```swift
import AppKit
import Foundation
import MenuBarPluginKit

final class ExamplePlugin: NSObject, MenuBarPlugin {
    let identifier = "com.example.example" // MUST match manifest.json "id"
    private var context: PluginContext?

    func activate(context: PluginContext) {
        self.context = context
        context.setSymbol("bolt.fill", accessibilityDescription: "Example")
        context.setTitle("Ready")
        context.setTooltip("Example Plugin")

        // Optional: coalesced repeating timer (auto-paused on sleep/display-off, auto-cancelled on deactivate)
        context.scheduleRepeating(interval: 30, leeway: 5) { [weak self] in
            self?.refresh()
        }
    }

    func deactivate() {
        // Release any retained resources, observers, or file handles here.
        // Timers scheduled through `context` are cancelled automatically.
        context = nil
    }

    // Optional: Lazy dropdown menu (called ONLY when clicked; items freed on close).
    func buildMenu() -> [MenuItemModel] {
        [
            .label("Read-only status", symbolName: "info.circle"),
            .separator(),
            .action("Do Something", symbolName: "play", keyEquivalent: "", isChecked: false) { [weak self] in
                self?.refresh()
            },
            .submenu("More", items: [
                .action("Sub-action") { /* ... */ }
            ])
        ]
    }

    // Optional: Lazy custom popover (left-click opens popover, right-click opens buildMenu()).
    // Created ONLY on click and deallocated immediately when closed.
    // Omit this method unless the plugin genuinely needs custom controls (sliders, text fields, charts).
    // func makePopoverViewController() -> NSViewController? { ... }
    // func preferredPopoverSize() -> NSSize { NSSize(width: 260, height: 180) }

    private func refresh() {
        context?.setTitle("Updated")
    }
}

@_cdecl("mbp_plugin_api_version")
public func pluginAPIVersion() -> Int32 {
    kMenuBarPluginAPIVersion
}

@_cdecl("mbp_create_plugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(ExamplePlugin()).toOpaque()
}
```

### `PluginContext` API Reference
- `context.pluginID: String`
- `context.pluginDirectoryURL: URL` — `<Plugins>/<PluginName>/`
- `context.dataDirectoryURL: URL` — `<Plugins>/<PluginName>/Data/`
- `try context.ensureDataDirectory() -> URL` — creates `Data/` on demand
- `context.setTitle(_ title: String?)` — thread-safe (dispatches to main if needed)
- `context.setSymbol(_ symbolName: String?, accessibilityDescription: String? = nil)` — SF Symbol template image
- `context.setImage(_ image: NSImage?)` — custom menu bar `NSImage` (preserves full color)
- `context.setTooltip(_ tooltip: String?)`
- `context.closePopover()`
- `context.scheduleRepeating(interval: TimeInterval, leeway: TimeInterval = -1, fireImmediately: Bool = false, handler: @escaping () -> Void) -> PluginTimerToken`
- `context.cancelAllTimers()`

### `MenuItemModel` Factory Methods
- `.label(_ title: String, symbolName: String? = nil)`
- `.action(_ title: String, symbolName: String? = nil, keyEquivalent: String = "", isChecked: Bool = false, isEnabled: Bool = true, handler: @escaping () -> Void)`
- `.separator()`
- `.submenu(_ title: String, symbolName: String? = nil, items: [MenuItemModel])`

---

## `manifest.json` Schema

```json
{
  "id": "com.local.my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "executable": "libMyPlugin.dylib",
  "author": "Author Name",
  "description": "Short description",
  "activation": {
    "mode": "always",
    "bundleIdentifiers": []
  }
}
```

- `executable` **must** be a simple filename inside the plugin folder (no `/` or `..`).
- `activation` is optional (defaults to `always`):
  - `"always"` — active whenever enabled.
  - `"whenAppRunning"` — active only while at least one app in `bundleIdentifiers` is running.
  - `"whenAppActive"` — active only while an app in `bundleIdentifiers` is the frontmost window.

---

## Efficiency Rules (IMPORTANT)

When generating plugins for this framework, follow these rules to keep CPU and RAM near zero:
1. **No SwiftUI, no WebKit (`WKWebView`), no Electron** — use pure AppKit (`MenuItemModel` by default, lightweight `NSViewController` only when custom controls are needed).
2. **Avoid spawning subprocesses on timers** — prefer native macOS/Darwin APIs (`Darwin`, `IOKit`, `CoreAudio`, `NSWorkspace`, `Foundation`) instead of shelling out to `bash`/`python` every few seconds.
3. **Prefer on-click or event-driven updates** — compute data inside `buildMenu()` when possible (0% background CPU). If a timer is needed, use `context.scheduleRepeating(interval:leeway:)` with the longest reasonable interval and a generous `leeway` (10–20% of interval).
4. **Clean up in `deactivate()`** — remove any `NotificationCenter` / `NSWorkspace` observers, `DispatchSource`s, or sockets so deactivated plugins consume 0 resources.
5. **Avoid retain cycles** — always capture `[weak self]` inside `scheduleRepeating` and `MenuItemModel.action` closures.

---

## Build, Install & Test Workflow

### Creating & Installing a New Plugin
```bash
# 0. On a fresh clone (if ./mbp doesn't exist yet), build the host app & CLI first
./scripts/build-app.sh

# 1. Scaffold
./mbp new MyPlugin

# 2. Edit MyPlugin/Sources/MyPluginPlugin.swift and MyPlugin/manifest.json
#    Also add a MyPlugin/.gitignore to ignore build/install/runtime artifacts:
#      *.dylib, *.dSYM/, *.swiftmodule, *.swiftdoc, *.swiftsourceinfo, Data/, .DS_Store

# 3. Compile against MenuBarPluginKit
./mbp build MyPlugin

# 4. Install self-contained folder into Plugins/MyPlugin/
./mbp install MyPlugin

# 5. Verify it is discovered
./mbp list
```

### Managing Plugins & Host Settings via CLI
```bash
./mbp list
./mbp MyPlugin enable
./mbp MyPlugin disable
./mbp MyPlugin rule always | running <bundleID...> | active <bundleID...> | default
./mbp persistent-icon [on|off]
./mbp reload
./mbp quit
```

### Direct `swiftc` Build (if not using `mbp`)
```bash
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
FRAMEWORKS_DIR="./MenuBarPlugins.app/Contents/Frameworks"
swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macos13.0" \
  -module-cache-path /tmp/mbp-module-cache \
  -O -parse-as-library -emit-library \
  -I "$FRAMEWORKS_DIR" -L "$FRAMEWORKS_DIR" -lMenuBarPluginKit \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  -o "Plugins/MyPlugin/libMyPlugin.dylib" \
  MyPlugin/Sources/*.swift
```

### Rebuilding the Framework & Running Tests
- Rebuild everything: `./scripts/build-app.sh`
- Run test suite (manifest validation, activation rules, scheduler, config persistence, and `FixturePlugin` compile/`dlopen` contract test): `./scripts/run-tests.sh`
- GitHub Actions CI (`.github/workflows/ci.yml`) runs both scripts on macOS on every push and PR.
