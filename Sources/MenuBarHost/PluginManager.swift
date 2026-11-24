import AppKit
import Foundation
import MenuBarPluginKit

/// Snapshot of a plugin's state for the Host Control Menu.
struct PluginSummary {
    let id: String
    let name: String
    let version: String
    let directoryURL: URL
    let isEnabled: Bool
    let isActive: Bool
    let effectiveRule: ActivationRule
    let hasUserRuleOverride: Bool
    let loadError: String?
}

/// Coordinates plugin discovery, conditional app-scoped activation, lifecycle, and hot-reload.
final class PluginManager {
    private struct ActiveInstance {
        let plugin: MenuBarPlugin
        let context: PluginContext
        let statusController: StatusItemController
    }

    let configStore: HostConfigStore
    let appMonitor: AppContextMonitor
    private let loader = PluginLoader()
    private let scheduler = PluginScheduler()
    private var directoryWatcher: DirectoryWatcher?
    private var powerMonitor: PowerStateMonitor?

    private var discovered: [String: DiscoveredPlugin] = [:]
    private var active: [String: ActiveInstance] = [:]
    private var loadErrors: [String: String] = [:]

    init(cliPluginsDirectory: String? = nil) {
        self.configStore = HostConfigStore(cliPluginsDirectory: cliPluginsDirectory)
        self.configStore.ensurePluginsDirectoryExists()

        var managerRef: PluginManager?
        self.appMonitor = AppContextMonitor {
            managerRef?.reevaluateActivations()
        }
        managerRef = self

        self.powerMonitor = PowerStateMonitor(
            onSuspend: { [weak self] in self?.scheduler.pauseAll() },
            onResume: { [weak self] in self?.scheduler.resumeAll() }
        )

        self.directoryWatcher = DirectoryWatcher(url: configStore.pluginsDirectoryURL) { [weak self] in
            self?.reloadAll()
        }

        reloadAll()
    }

    deinit {
        deactivateAll()
    }

    // MARK: - Public API for HostMenuController

    var pluginsDirectoryURL: URL {
        configStore.pluginsDirectoryURL
    }

    var configFileURL: URL {
        configStore.configFileURL
    }

    func summaries() -> [PluginSummary] {
        discovered.values
            .sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending }
            .map { item in
                let id = item.manifest.id
                let overrideRule = configStore.activationOverride(for: id)
                let effective = overrideRule ?? item.manifest.activation ?? .always
                return PluginSummary(
                    id: id,
                    name: item.manifest.name,
                    version: item.manifest.version,
                    directoryURL: item.directoryURL,
                    isEnabled: configStore.isPluginEnabled(id),
                    isActive: active[id] != nil,
                    effectiveRule: effective,
                    hasUserRuleOverride: overrideRule != nil,
                    loadError: loadErrors[id]
                )
            }
    }

    func setEnabled(_ enabled: Bool, for pluginID: String) {
        configStore.setPluginEnabled(enabled, for: pluginID)
        reevaluateActivations()
    }

    func setActivationOverride(_ rule: ActivationRule?, for pluginID: String) {
        configStore.setActivationOverride(rule, for: pluginID)
        reevaluateActivations()
    }

    func setCustomPluginsDirectory(_ url: URL?) {
        deactivateAll()
        discovered.removeAll()
        loadErrors.removeAll()
        configStore.setCustomPluginsDirectory(url)
        configStore.ensurePluginsDirectoryExists()
        directoryWatcher?.restart(watching: configStore.pluginsDirectoryURL)
        reloadAll()
    }

    func reloadAll() {
        let freshList = loader.discoverPlugins(in: configStore.pluginsDirectoryURL)
        let freshMap = Dictionary(uniqueKeysWithValues: freshList.map { ($0.manifest.id, $0) })

        // Deactivate plugins whose folder was removed.
        for activeID in Array(active.keys) where freshMap[activeID] == nil {
            deactivatePlugin(id: activeID)
        }

        discovered = freshMap
        loadErrors.removeAll()
        reevaluateActivations()
    }

    func deactivateAll() {
        for id in Array(active.keys) {
            deactivatePlugin(id: id)
        }
        scheduler.cancelAll()
    }

    // MARK: - Conditional Activation Engine

    func reevaluateActivations() {
        let running = appMonitor.runningBundleIDs
        let frontmost = appMonitor.activeBundleID

        for (id, item) in discovered {
            let enabled = configStore.isPluginEnabled(id)
            let rule = configStore.activationOverride(for: id) ?? item.manifest.activation ?? .always
            let shouldBeActive = enabled && rule.isSatisfied(runningBundleIDs: running, activeBundleID: frontmost)

            if shouldBeActive && active[id] == nil {
                activatePlugin(item)
            } else if !shouldBeActive && active[id] != nil {
                deactivatePlugin(id: id)
            }
        }
    }

    private func activatePlugin(_ item: DiscoveredPlugin) {
        let id = item.manifest.id
        do {
            let plugin = try loader.instantiate(item)
            let statusController = StatusItemController(plugin: plugin, defaultTitle: item.manifest.name)

            let context = PluginContext(
                pluginID: id,
                pluginDirectoryURL: item.directoryURL,
                scheduler: scheduler,
                onSetTitle: { [weak statusController] title in
                    statusController?.setTitle(title)
                },
                onSetSymbol: { [weak statusController] symbol, desc in
                    statusController?.setSymbol(symbol, accessibilityDescription: desc)
                },
                onSetTooltip: { [weak statusController] tooltip in
                    statusController?.setTooltip(tooltip)
                },
                onClosePopover: { [weak statusController] in
                    statusController?.closePopover()
                }
            )

            active[id] = ActiveInstance(plugin: plugin, context: context, statusController: statusController)
            loadErrors.removeValue(forKey: id)
            plugin.activate(context: context)
        } catch {
            loadErrors[id] = error.localizedDescription
            fputs("[MenuBarHost] Could not activate '\(id)': \(error.localizedDescription)\n", stderr)
        }
    }

    private func deactivatePlugin(id: String) {
        guard let instance = active.removeValue(forKey: id) else { return }
        instance.context.cancelAllTimers()
        instance.plugin.deactivate()
        instance.statusController.teardown()
    }
}
