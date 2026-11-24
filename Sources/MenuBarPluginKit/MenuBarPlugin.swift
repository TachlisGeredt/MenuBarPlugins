import AppKit
import Foundation

/// Core protocol implemented by every MenuBarPlugins native plugin.
///
/// Plugins export a C factory symbol:
/// ```swift
/// @_cdecl("mbp_create_plugin")
/// public func createPlugin() -> UnsafeMutableRawPointer {
///     Unmanaged.passRetained(MyPlugin()).toOpaque()
/// }
/// ```
@objc public protocol MenuBarPlugin: AnyObject {
    /// Unique reverse-DNS identifier matching `manifest.json`.
    var identifier: String { get }

    /// Called when the plugin becomes active (enabled AND its activation rule is satisfied).
    func activate(context: PluginContext)

    /// Called when the plugin is disabled, its activation rule is no longer met, or the host quits.
    /// Plugins should release any resources here. Timers scheduled via `PluginContext` are cancelled automatically.
    func deactivate()

    /// Optional: Return lightweight menu items built lazily *only when the user clicks* the menu bar icon.
    @objc optional func buildMenu() -> [MenuItemModel]

    /// Optional: Return a custom `NSViewController` to display in a lazy `NSPopover` on click.
    /// The host instantiates this only when clicked and deallocates it when the popover closes.
    @objc optional func makePopoverViewController() -> NSViewController?

    /// Optional: Preferred content size for the popover.
    @objc optional func preferredPopoverSize() -> NSSize
}

/// Standard symbol name exported by every plugin dynamic library.
public let kMenuBarPluginFactorySymbol = "mbp_create_plugin"
