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
    private var distributedObservers: [NSObjectProtocol] = []

    private var discovered: [String: DiscoveredPlugin] = [:]
    private var active: [String: ActiveInstance] = [:]
    private var loadErrors: [String: String] = [:]

    /// Called whenever active plugins or host settings change (used to update puzzle icon visibility).
    var onStateChanged: (() -> Void)?

    /// Provides the lazy "Manage Icons ▸" submenu attached to every active plugin's menu.
    var makeManageMenuItem: (() -> NSMenuItem)?

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
    }

    deinit {
        let dnc = DistributedNotificationCenter.default()
        for token in distributedObservers {
            dnc.removeObserver(token)
        }
        distributedObservers.removeAll()
        deactivateAll()
    }

    /// Starts directory watching, CLI notification observers, and initial plugin discovery.
    func start() {
        self.directoryWatcher = DirectoryWatcher(url: configStore.pluginsDirectoryURL) { [weak self] in
            self?.reloadAll()
        }
        registerDistributedObservers()
        reloadAll()
    }

    private func registerDistributedObservers() {
        let dnc = DistributedNotificationCenter.default()

        let reloadConfigToken = dnc.addObserver(
            forName: HostNotification.reloadConfig,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadConfigFromDisk()
        }

        let reloadPluginsToken = dnc.addObserver(
            forName: HostNotification.reloadPlugins,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadAll()
        }

        let quitToken = dnc.addObserver(
            forName: HostNotification.quit,
            object: nil,
            queue: .main
        ) { _ in
            NSApp.terminate(nil)
        }

        distributedObservers = [reloadConfigToken, reloadPluginsToken, quitToken]
    }

    // MARK: - Public API for HostMenuController

    var pluginsDirectoryURL: URL {
        configStore.pluginsDirectoryURL
    }

    var configFileURL: URL {
        configStore.configFileURL
    }

    var activePluginCount: Int {
        active.count
    }

    var persistentIcon: Bool {
        configStore.persistentIcon
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

    func setPersistentIcon(_ enabled: Bool) {
        configStore.setPersistentIcon(enabled)
        onStateChanged?()
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

    func reloadConfigFromDisk() {
        let previousPluginsDir = configStore.pluginsDirectoryURL
        configStore.reloadFromDisk()
        if configStore.pluginsDirectoryURL != previousPluginsDir {
            deactivateAll()
            discovered.removeAll()
            loadErrors.removeAll()
            configStore.ensurePluginsDirectoryExists()
            directoryWatcher?.restart(watching: configStore.pluginsDirectoryURL)
            reloadAll()
        } else {
            reevaluateActivations()
        }
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
        onStateChanged?()
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

        onStateChanged?()
    }

    private func activatePlugin(_ item: DiscoveredPlugin) {
        let id = item.manifest.id
        do {
            let plugin = try loader.instantiate(item)
            let statusController = StatusItemController(
                plugin: plugin,
                defaultTitle: item.manifest.name,
                makeManageMenuItem: makeManageMenuItem
            )

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
                onSetImage: { [weak statusController] image in
                    statusController?.setImage(image)
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
