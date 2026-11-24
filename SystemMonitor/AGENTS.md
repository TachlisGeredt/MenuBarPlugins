# AGENTS.md — Modifying the SystemMonitor Plugin

Guide for AI coding agents and developers modifying the **SystemMonitor** plugin. Follow the root [AGENTS.md](../AGENTS.md) rules in addition to the plugin-specific architecture notes below.

---

## Folder Structure

```text
SystemMonitor/
├── manifest.json                   # Plugin metadata (id: com.local.system-monitor)
├── .gitignore                      # Ignores *.dylib, build artifacts, Data/, .DS_Store
├── Resources/
│   ├── cpu.png                     # CPU chip icon (opaque outer white, transparent inner square)
│   ├── ram.png                     # RAM stick icon (opaque outer white, transparent inner body)
│   └── thermal.png                 # Thermal chip icon (opaque outer white, transparent flame cutout)
└── Sources/
    ├── SystemMetrics.swift         # Stack-only Mach CPU/RAM sampling + ProcessInfo.thermalState
    ├── IconRenderer.swift          # One-time PNG preprocessing + dirty-checked 2-blit CGContext renderer
    └── SystemMonitorPlugin.swift   # MenuBarPlugin entry point, 2 Hz timer, lazy menu, Data/settings.json
```

---

## Key Architecture & Invariants

### 1. PNG Asset Contract (`Resources/` + `IconRenderer.swift`)
If you replace or edit any of the three PNG icons, keep this alpha contract in mind:
- **Interior fillable region**: `IconRenderer.prepareIcon` derives the fill mask directly from `255 - originalAlpha`. Only the region that should fill left-to-right with the gradient should be transparent in the source PNG.
- **Outer background**: Corner BFS flood-fill strips near-white opaque pixels (`r,g,b >= 235, a >= 240`) connected to the image edges.
- **Monochrome conversion modes**:
  - `.darkInkOnWhite` (`ram.png`, `thermal.png`): Treats dark lines as foreground and white hollows (e.g., RAM chip/pin interiors) as transparent.
  - `.allOpaqueForeground` (`cpu.png`): Treats all non-exterior opaque pixels (border, pins, and light-colored `"CPU"` text) as solid monochrome foreground.
- **Target `@2x` dimensions**: Canvas height is `36 px` (`18 pt`). CPU/Thermal are `36×36 px`; RAM is `56×28 px` vertically centered inside `36 px`, with a `10 px` (`5 pt`) gap between icons.

### 2. Performance & Memory Constraints
- **No subprocesses, no SwiftUI, no WebKit**: Keep all metric sampling in native Mach (`HOST_CPU_LOAD_INFO`, `HOST_VM_INFO64`) and `Foundation` (`ProcessInfo`).
- **Keep per-tick work O(1) and allocation-free**:
  - `IconRenderer` pre-bakes `foregroundLight`, `foregroundDark`, and `gradientFilled` once in `init(resourcesDirectoryURL:)`.
  - Never allocate `CGGradient` or re-run pixel flood-fills inside `renderIfNeeded(...)`.
  - Preserve `RenderKey` dirty-checking so unchanged quantized fill widths perform **0 CoreGraphics calls** and skip `context.setImage(...)`.
- **Timer scheduling**: Always use `context.scheduleRepeating(interval:leeway:)` (currently `0.5 s` with `0.1 s` leeway) so `PluginScheduler` pauses updates automatically on sleep/display-off and cancels timers on `deactivate()`.

### 3. State, Menu & Persistence (`SystemMonitorPlugin.swift`)
- **Appearance detection**: Listens to `AppleInterfaceThemeChangedNotification` via `DistributedNotificationCenter`, invalidates `IconRenderer`'s cache, and re-renders using `NSApp.effectiveAppearance`.
- **Thermal notifications**: Listens to `ProcessInfo.thermalStateDidChangeNotification` so switching between `cpu.png` and `thermal.png` happens immediately.
- **Click menu**: `buildMenu()` is lazy (runs only on click). Both `CPU: ...` and `RAM: ...` rows always appear; their checkmarks control `settings.showCPU` and `settings.showRAM`. When both are `false`, the plugin switches to SF Symbol `gauge.with.dots.needle.bottom.50percent` so the status item remains clickable.
- **Storage**: Persist settings only inside `context.ensureDataDirectory()` (`Plugins/SystemMonitor/Data/settings.json`). Never write outside the plugin's folder.
- **Cleanup**: Always remove `thermalObserver` and `appearanceObserver`, and nil out `metrics`, `renderer`, and `context` in `deactivate()`.

---

## Build, Install & Verify Workflow

Run from the repository root:

```bash
# Compile libSystemMonitor.dylib
./mbp build SystemMonitor

# Install manifest.json, libSystemMonitor.dylib, and Resources/ into Plugins/SystemMonitor/
./mbp install SystemMonitor

# Verify plugin discovery
./mbp list

# Reload running host app (or launch it)
./mbp reload
```

If you modify `MenuBarPluginKit`, `MenuBarHost`, or `mbp-cli`, rebuild the host first and run the framework test suite:

```bash
./scripts/build-app.sh
./scripts/run-tests.sh
```
