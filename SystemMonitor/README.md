# SystemMonitor

An ultra-lightweight macOS menu bar plugin for **MenuBarPlugins** that displays live **CPU usage**, **RAM usage**, and **thermal throttling** status at **2 Hz** using custom gradient-filled monochrome icons.

## What It Does

- **Menu Bar Icons (CPU on the left, RAM on the right)**:
  - Uses three custom PNG icons (`cpu.png`, `ram.png`, `thermal.png`) converted at load time into crisp single-color monochrome outlines that automatically match the macOS menu bar (**black** in Light Mode, **white** in Dark Mode).
  - Fills only the transparent interior of each icon **left to right** in proportion to current usage (`0%`–`100%`), revealing a fixed **green → yellow → red** gradient.
  - **Thermal Throttling**: When macOS enters `.serious` or `.critical` thermal state, the CPU icon automatically swaps to the thermal throttling flame icon (also filled left-to-right by CPU %).
- **Click Dropdown Menu**:
  - Always displays live **CPU %**, **RAM used / total GB (%)**, and **Thermal state** (`Normal`, `Fair`, `Throttling (Serious)`, `Throttling (Critical)`).
  - Clicking the **CPU** or **RAM** row toggles its checkmark to show or hide that icon in the menu bar (both stats always remain visible in the dropdown).
  - If both icons are unchecked, a small fallback gauge symbol appears so the menu stays accessible.
  - Visibility preferences persist inside `Plugins/SystemMonitor/Data/settings.json`.

## How It Works

### 1. Native System Metrics (`Sources/SystemMetrics.swift`)
All metrics are collected via stack-allocated Darwin/Foundation APIs with **zero subprocesses** and **zero heap allocations per tick**:
- **CPU %**: `host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, ...)` computes deltas across `user`, `system`, `nice`, and `idle` ticks between samples.
- **RAM % & GB**: `host_statistics64(mach_host_self(), HOST_VM_INFO64, ...)` calculates Activity Monitor's **Memory Used** formula: `(internal - purgeable + wired + compressed) * pageSize / physicalMemory` (excluding purgeable file cache that macOS reclaims on demand).
- **Thermal State**: Reads `ProcessInfo.processInfo.thermalState` and subscribes to `ProcessInfo.thermalStateDidChangeNotification` for immediate icon swaps.

### 2. Pre-Baked Icon Compositing (`Sources/IconRenderer.swift`)
To keep CPU usage near zero at 2 updates/second:
- **One-time startup preprocessing**: On `activate()`, each PNG in `Resources/` is flood-filled from its edges to remove outer white margins, cropped to its content bounding box, converted into Light (black) and Dark (white) `@2x` monochrome foreground `CGImage`s, and paired with a pre-rendered full-width green → yellow → red gradient masked to the PNG's original transparent interior (`255 - alpha`).
- **Per-tick dirty check & 2-blit rendering**: Each tick quantizes CPU and RAM fill widths to integer `@2x` pixels. If nothing changed since the previous tick, rendering is skipped completely (0 CoreGraphics calls). When a change occurs, a single reusable `CGContext` (~14 KB) clears and blits each visible icon in two draws: the clipped gradient layer, then the monochrome foreground layer on top.

### 3. Lifecycle & Power Efficiency (`Sources/SystemMonitorPlugin.swift`)
- Schedules updates through `context.scheduleRepeating(interval: 0.5, leeway: 0.1, fireImmediately: true)`, which coalesces timer wakeups and automatically pauses on sleep or display-off.
- Builds the dropdown menu lazily in `buildMenu()` only when clicked.
- Releases all observers, cached buffers, and references in `deactivate()`.

## Build & Install

From the MenuBarPlugins project root:

```bash
# 1. Build the host app & CLI (if not already built)
./scripts/build-app.sh

# 2. Build and install SystemMonitor into Plugins/SystemMonitor/
./mbp build SystemMonitor
./mbp install SystemMonitor

# 3. Verify discovery and launch/reload
./mbp list
open MenuBarPlugins.app   # or ./mbp reload if already running
```
