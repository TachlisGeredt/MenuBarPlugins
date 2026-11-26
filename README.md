# MenuBarPlugins

An ultra-lightweight, open, and modular macOS menu bar plugin framework built in pure **Swift + AppKit** (no SwiftUI, no Electron, no WebKit, no Xcode app required).

---

## What It Does

`MenuBarPlugins` lets you run small, modular plugins directly in your macOS menu bar while using minimal CPU and RAM:

- **One tiny host app (`MenuBarPlugins.app`)**: Runs silently in the background (`LSUIElement = true`, no Dock icon) and gives each active plugin its own menu bar icon.
- **Zero-clutter control menu**:
  - When **no plugins are active**, a **puzzle-piece icon** appears in the menu bar (controlled by **Settings ▸ Persistent Icon**, on by default).
  - As soon as **one or more plugins are active**, the puzzle icon automatically hides and every active plugin's menu includes a **Manage Icons ▸** submenu at the bottom with all host controls.
  - Turn **Settings ▸ Persistent Icon** off to never show the puzzle icon, even when 0 plugins are active.
- **App-specific activation rules**: Any plugin can be configured—via the menu bar, the `mbp` CLI, or `config.json`—to only run when a specific app is **running** (`whenAppRunning`) or **currently focused** (`whenAppActive`). When the condition isn't met, the plugin is deactivated and hidden from your menu bar.
- **100% portable & self-contained**: Move the `MenuBarPlugins` folder anywhere on your Mac. Nothing is written to `~/Library/Application Support/`.

---

## Plugins

<!-- PLUGINS:START -->
| Plugin | Description |
| --- | --- |
| [SystemMonitor](https://github.com/TachlisGeredt/SystemMonitor) | Lightweight CPU, RAM, and thermal throttling menu bar monitor. |
<!-- PLUGINS:END -->

---

## How It Works

```text
MenuBarPlugins/                  ← can live anywhere on your Mac
├── MenuBarPlugins.app           ← lightweight macOS host app (~318 KB)
│   └── Contents/Frameworks/
│       └── libMenuBarPluginKit.dylib   ← shared plugin SDK (~197 KB)
├── mbp                          ← optional CLI helper for building new plugins
├── config.json                  ← enabled plugins & per-plugin app rules
└── Plugins/
    └── MyPlugin/                ← each plugin is 100% self-contained
        ├── manifest.json        ← plugin metadata & default activation rule
        ├── libMyPlugin.dylib
        └── Data/                ← created lazily only if the plugin saves data
```

### Why It Uses Minimal CPU & RAM
1. **Native in-process plugins (`.dylib`)**: Unlike script-based menu bar runners that repeatedly spawn shell/Python subprocesses, plugins are compiled native Swift libraries loaded directly into a single lightweight AppKit process.
2. **Lazy UI**: Dropdown menus (`NSMenu`) and optional custom mini-panels (`NSPopover`) are created **only when you click** a plugin's icon and freed immediately when closed.
3. **Zero-polling system monitors**:
   - **Hot-reload**: Watches `Plugins/` with macOS `kqueue` (0% CPU).
   - **App rules**: Uses push-based `NSWorkspace` notifications for app launch, quit, and focus changes (0% CPU).
   - **Sleep/display-off pause**: Automatically suspends all plugin timers when your Mac sleeps or turns off its display, and resumes them on wake.
   - **Coalesced timers**: Repeating timers use `DispatchSourceTimer` with generous leeway so macOS groups CPU wakeups together.

---

## Building & Running

Requires macOS 13+ and Apple Command Line Tools (`xcode-select --install` — full Xcode is **not** required):

```bash
# Build MenuBarPlugins.app and the mbp CLI
./scripts/build-app.sh

# Launch the app (or double-click MenuBarPlugins.app in Finder)
open MenuBarPlugins.app

# Run automated unit tests + plugin ABI/dlopen contract test
./scripts/run-tests.sh
```

### Plugin Compatibility & CI
- **ABI-stable SDK**: `libMenuBarPluginKit.dylib` is compiled with Swift Library Evolution (`-enable-library-evolution`), so additive framework updates keep already-compiled plugins working without rebuilding them.
- **API Version Guard**: Plugins can export `mbp_plugin_api_version` (included automatically by `mbp new`) so intentional major API changes show a clear rebuild message instead of crashing.
- **Automated Contract Tests & CI**: `./scripts/run-tests.sh` compiles and dynamically loads a reference `FixturePlugin` covering every public `MenuBarPluginKit` API, and [.github/workflows/ci.yml](.github/workflows/ci.yml) runs the full build and test suite on every push and pull request.

Once running, manage plugins from the **puzzle-piece icon** (when 0 plugins are active), from **Manage Icons ▸** at the bottom of any active plugin's menu, or via the `mbp` CLI.

### Optional: Add `mbp` to your `PATH`

Symlink `mbp` (do not copy it) so it stays next to `MenuBarPlugins.app` and works from any directory:

```bash
# User-local (no sudo; ensure ~/.local/bin is in your PATH)
mkdir -p ~/.local/bin && ln -sf "$PWD/mbp" ~/.local/bin/mbp

# Or system-wide (already in default macOS PATH)
sudo ln -sf "$PWD/mbp" /usr/local/bin/mbp
```

---

## Managing Plugins via CLI

All `mbp` management commands update `config.json` and notify a running `MenuBarPlugins.app` live:

```bash
# List installed plugins, their enabled/rule status, and Persistent Icon setting
mbp list

# Enable or disable a plugin (matches plugin ID, name, or folder name)
mbp MyPlugin enable
mbp MyPlugin disable

# Set app-specific activation rules
mbp MyPlugin rule always
mbp MyPlugin rule running com.apple.Safari
mbp MyPlugin rule active com.apple.Safari
mbp MyPlugin rule default

# Check or toggle the fallback puzzle icon (default: on)
mbp persistent-icon
mbp persistent-icon off
mbp persistent-icon on

# Ask the running host app to re-scan Plugins/ or quit
mbp reload
mbp quit
```

---

## How to Install a Plugin

Installing a pre-built plugin requires **no terminal commands**:

1. Copy or drag the plugin's folder (containing `manifest.json` and its `.dylib`) into `MenuBarPlugins/Plugins/`.
2. `MenuBarPlugins.app` detects the new folder automatically via `kqueue` and activates it immediately (or click **Reload Plugins** in the puzzle-piece menu).

To **uninstall** a plugin, simply delete its folder from `Plugins/`—there are no leftover files anywhere else on your Mac.

---

## How to Create & Add Your Own Plugin

### Option 1: Using the `mbp` CLI helper (fastest)

```bash
# 1. Scaffold a new plugin folder with manifest.json and starter Swift code
./mbp new MyPlugin

# 2. Edit MyPlugin/Sources/MyPluginPlugin.swift and MyPlugin/manifest.json

# 3. Compile it into MyPlugin/libMyPlugin.dylib
./mbp build MyPlugin

# 4. Install the self-contained folder into Plugins/MyPlugin/
./mbp install MyPlugin

# List installed plugins
./mbp list
```

### Option 2: Manual Plugin Structure

Every plugin needs just two files inside `Plugins/<PluginName>/`:

1. **`manifest.json`**:
   ```json
   {
     "id": "com.example.my-plugin",
     "name": "My Plugin",
     "version": "1.0.0",
     "executable": "libMyPlugin.dylib",
     "author": "Your Name",
     "description": "What this plugin does",
     "activation": {
       "mode": "always",
       "bundleIdentifiers": []
     }
   }
   ```
   Supported `activation.mode` values: `"always"`, `"whenAppRunning"`, `"whenAppActive"`.

2. **Swift source** implementing `MenuBarPlugin` and exporting `@_cdecl("mbp_create_plugin")`:
   ```swift
   import AppKit
   import Foundation
   import MenuBarPluginKit

   final class MyPlugin: NSObject, MenuBarPlugin {
       let identifier = "com.example.my-plugin"
       private var context: PluginContext?

       func activate(context: PluginContext) {
           self.context = context
           context.setSymbol("star", accessibilityDescription: "My Plugin")
           context.setTitle("Hello")
       }

       func deactivate() {
           context = nil
       }

       // Optional: built lazily only when clicked
       func buildMenu() -> [MenuItemModel] {
           [
               .label("Status: OK"),
               .separator(),
               .action("Update Title") { [weak self] in
                   self?.context?.setTitle("Clicked!")
               }
           ]
       }
   }

   @_cdecl("mbp_create_plugin")
   public func createPlugin() -> UnsafeMutableRawPointer {
       Unmanaged.passRetained(MyPlugin()).toOpaque()
   }
   ```

---

## Building Plugins with AI

This repository includes an **[AGENTS.md](AGENTS.md)** file—a dedicated specification written for AI coding assistants (Antigravity, Claude Code, Codex, Cursor, Gemini CLI, etc.) explaining the exact plugin API, resource-efficiency rules, and build commands so any AI can generate and install working plugins for you automatically.

---

## Built With

- **AI Harness**: Antigravity
- **Model & Settings**: Gemini 4 Neon (Medium)
