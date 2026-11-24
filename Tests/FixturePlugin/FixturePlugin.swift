import AppKit
import Foundation
import MenuBarPluginKit

/// Reference contract plugin used ONLY by `./scripts/run-tests.sh`.
/// Exercises every public API in `MenuBarPluginKit` so accidental breaking changes fail CI immediately.
final class FixturePlugin: NSObject, MenuBarPlugin {
    let identifier = "com.test.fixture"
    private var context: PluginContext?

    func activate(context: PluginContext) {
        self.context = context
        _ = context.pluginID
        _ = context.pluginDirectoryURL
        _ = context.dataDirectoryURL
        _ = try? context.ensureDataDirectory()

        context.setTitle("Fixture")
        context.setSymbol("checkmark.circle", accessibilityDescription: "Fixture")
        context.setImage(NSImage(size: NSSize(width: 16, height: 16)))
        context.setTooltip("Fixture Tooltip")

        context.scheduleRepeating(interval: 60, leeway: 5, fireImmediately: false) { [weak self] in
            self?.context?.setTitle("Tick")
        }
    }

    func deactivate() {
        context?.closePopover()
        context?.cancelAllTimers()
        context = nil
    }

    func buildMenu() -> [MenuItemModel] {
        [
            .label("Status: OK", symbolName: "info.circle"),
            .separator(),
            .action("Ping", symbolName: "bolt", keyEquivalent: "p", isChecked: true, isEnabled: true) { [weak self] in
                self?.context?.setTitle("Pong")
            },
            .submenu("More", symbolName: "ellipsis.circle", items: [
                .action("Nested") { [weak self] in
                    self?.context?.setTooltip("Nested")
                }
            ])
        ]
    }

    func makePopoverViewController() -> NSViewController? {
        NSViewController()
    }

    func preferredPopoverSize() -> NSSize {
        NSSize(width: 240, height: 160)
    }
}

@_cdecl("mbp_plugin_api_version")
public func pluginAPIVersion() -> Int32 {
    kMenuBarPluginAPIVersion
}

@_cdecl("mbp_create_plugin")
public func createPlugin() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(FixturePlugin()).toOpaque()
}
