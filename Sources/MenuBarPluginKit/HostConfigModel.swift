import Foundation

/// Per-plugin user preferences stored in portable `config.json`.
public struct PluginUserConfig: Codable, Equatable {
    public var enabled: Bool
    public var activationOverride: ActivationRule?

    public init(enabled: Bool = true, activationOverride: ActivationRule? = nil) {
        self.enabled = enabled
        self.activationOverride = activationOverride
    }
}

/// Portable configuration file saved alongside `MenuBarPlugins.app` at `<Root>/config.json`.
public struct HostConfigFile: Codable, Equatable {
    public var customPluginsDirectory: String?
    /// When `true` (default), the puzzle icon is shown whenever 0 plugin icons are active.
    /// When `false`, the puzzle icon is never shown.
    public var persistentIcon: Bool
    public var plugins: [String: PluginUserConfig]

    public init(
        customPluginsDirectory: String? = nil,
        persistentIcon: Bool = true,
        plugins: [String: PluginUserConfig] = [:]
    ) {
        self.customPluginsDirectory = customPluginsDirectory
        self.persistentIcon = persistentIcon
        self.plugins = plugins
    }

    private enum CodingKeys: String, CodingKey {
        case customPluginsDirectory
        case persistentIcon
        case plugins
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.customPluginsDirectory = try container.decodeIfPresent(String.self, forKey: .customPluginsDirectory)
        self.persistentIcon = try container.decodeIfPresent(Bool.self, forKey: .persistentIcon) ?? true
        self.plugins = try container.decodeIfPresent([String: PluginUserConfig].self, forKey: .plugins) ?? [:]
    }
}

/// Distributed notifications used by `mbp` CLI to notify a running `MenuBarPlugins.app` instance (0% polling).
public enum HostNotification {
    public static let reloadConfig = Notification.Name("com.menubarplugins.host.reloadConfig")
    public static let reloadPlugins = Notification.Name("com.menubarplugins.host.reloadPlugins")
    public static let quit = Notification.Name("com.menubarplugins.host.quit")
}
