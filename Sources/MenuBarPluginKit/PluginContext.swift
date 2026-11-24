import AppKit
import Foundation

/// Host-provided context handed to each active plugin.
/// Gives plugins safe, lightweight control over their menu bar item and timers.
@objcMembers
public final class PluginContext: NSObject {
    public let pluginID: String
    /// The plugin's self-contained folder inside `Plugins/<PluginName>/`.
    public let pluginDirectoryURL: URL
    /// Lazy per-plugin storage folder at `<PluginDirectory>/Data/`.
    /// Not created on disk unless the plugin calls `ensureDataDirectory()`.
    public let dataDirectoryURL: URL

    private let scheduler: PluginScheduler
    private let onSetTitle: (String?) -> Void
    private let onSetSymbol: (String?, String?) -> Void
    private let onSetTooltip: (String?) -> Void
    private let onClosePopover: () -> Void
    private var timerTokens: [PluginTimerToken] = []

    public init(
        pluginID: String,
        pluginDirectoryURL: URL,
        scheduler: PluginScheduler,
        onSetTitle: @escaping (String?) -> Void,
        onSetSymbol: @escaping (String?, String?) -> Void,
        onSetTooltip: @escaping (String?) -> Void,
        onClosePopover: @escaping () -> Void
    ) {
        self.pluginID = pluginID
        self.pluginDirectoryURL = pluginDirectoryURL
        self.dataDirectoryURL = pluginDirectoryURL.appendingPathComponent("Data", isDirectory: true)
        self.scheduler = scheduler
        self.onSetTitle = onSetTitle
        self.onSetSymbol = onSetSymbol
        self.onSetTooltip = onSetTooltip
        self.onClosePopover = onClosePopover
    }

    /// Creates `<PluginDirectory>/Data/` on demand and returns its URL.
    public func ensureDataDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: dataDirectoryURL, withIntermediateDirectories: true)
        return dataDirectoryURL
    }

    /// Updates the text displayed in the macOS menu bar for this plugin.
    public func setTitle(_ title: String?) {
        if Thread.isMainThread {
            onSetTitle(title)
        } else {
            DispatchQueue.main.async { self.onSetTitle(title) }
        }
    }

    /// Updates the SF Symbol displayed in the macOS menu bar for this plugin.
    public func setSymbol(_ symbolName: String?, accessibilityDescription: String? = nil) {
        if Thread.isMainThread {
            onSetSymbol(symbolName, accessibilityDescription)
        } else {
            DispatchQueue.main.async { self.onSetSymbol(symbolName, accessibilityDescription) }
        }
    }

    /// Sets the hover tooltip on the plugin's menu bar item.
    public func setTooltip(_ tooltip: String?) {
        if Thread.isMainThread {
            onSetTooltip(tooltip)
        } else {
            DispatchQueue.main.async { self.onSetTooltip(tooltip) }
        }
    }

    /// Closes the plugin's popover if it is currently open.
    public func closePopover() {
        if Thread.isMainThread {
            onClosePopover()
        } else {
            DispatchQueue.main.async { self.onClosePopover() }
        }
    }

    /// Schedules a power-efficient repeating timer automatically paused on sleep/display-off
    /// and automatically cancelled when the plugin deactivates.
    @discardableResult
    public func scheduleRepeating(
        interval: TimeInterval,
        leeway: TimeInterval = -1,
        fireImmediately: Bool = false,
        handler: @escaping () -> Void
    ) -> PluginTimerToken {
        let token = scheduler.scheduleRepeating(
            interval: interval,
            leeway: leeway > 0 ? leeway : nil,
            fireImmediately: fireImmediately,
            handler: handler
        )
        timerTokens.append(token)
        return token
    }

    /// Cancels all timers created by this plugin.
    public func cancelAllTimers() {
        for token in timerTokens {
            token.cancel()
        }
        timerTokens.removeAll()
    }
}
