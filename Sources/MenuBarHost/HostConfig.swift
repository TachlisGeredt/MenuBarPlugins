import Foundation
import MenuBarPluginKit

/// Manages portable paths (`Plugins/`, `config.json`) without forcing `~/Library/Application Support/`.
final class HostConfigStore {
    let rootDirectoryURL: URL
    let configFileURL: URL
    private let cliPluginsDirectoryOverride: URL?
    private(set) var config: HostConfigFile

    init(cliPluginsDirectory: String? = nil) {
        self.rootDirectoryURL = HostConfigStore.resolvePortableRoot()
        self.configFileURL = rootDirectoryURL.appendingPathComponent("config.json")

        if let cliPath = cliPluginsDirectory, !cliPath.isEmpty {
            self.cliPluginsDirectoryOverride = URL(fileURLWithPath: (cliPath as NSString).expandingTildeInPath, isDirectory: true)
        } else if let envPath = ProcessInfo.processInfo.environment["MBP_PLUGINS_DIR"], !envPath.isEmpty {
            self.cliPluginsDirectoryOverride = URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            self.cliPluginsDirectoryOverride = nil
        }

        self.config = HostConfigFile()
        reloadFromDisk()
    }

    /// Resolves the portable folder containing `MenuBarPlugins.app` (or current working directory for CLI runs).
    static func resolvePortableRoot() -> URL {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    /// Re-reads `config.json` from disk (e.g., after external CLI edits).
    func reloadFromDisk() {
        if let data = try? Data(contentsOf: configFileURL),
           let decoded = try? JSONDecoder().decode(HostConfigFile.self, from: data) {
            self.config = decoded
        } else {
            self.config = HostConfigFile()
        }
    }

    /// Active `Plugins/` directory: CLI/env override > user-chosen folder > `<Root>/Plugins/`.
    var pluginsDirectoryURL: URL {
        if let cliOverride = cliPluginsDirectoryOverride {
            return cliOverride
        }
        if let custom = config.customPluginsDirectory, !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return rootDirectoryURL.appendingPathComponent("Plugins", isDirectory: true)
    }

    var persistentIcon: Bool {
        config.persistentIcon
    }

    func setPersistentIcon(_ enabled: Bool) {
        config.persistentIcon = enabled
        save()
    }

    func ensurePluginsDirectoryExists() {
        try? FileManager.default.createDirectory(at: pluginsDirectoryURL, withIntermediateDirectories: true)
    }

    func isPluginEnabled(_ id: String) -> Bool {
        config.plugins[id]?.enabled ?? true
    }

    func setPluginEnabled(_ enabled: Bool, for id: String) {
        var entry = config.plugins[id] ?? PluginUserConfig()
        entry.enabled = enabled
        config.plugins[id] = entry
        save()
    }

    func activationOverride(for id: String) -> ActivationRule? {
        config.plugins[id]?.activationOverride
    }

    func setActivationOverride(_ rule: ActivationRule?, for id: String) {
        var entry = config.plugins[id] ?? PluginUserConfig()
        entry.activationOverride = rule
        config.plugins[id] = entry
        save()
    }

    func setCustomPluginsDirectory(_ url: URL?) {
        config.customPluginsDirectory = url?.path
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: configFileURL, options: .atomic)
    }
}
