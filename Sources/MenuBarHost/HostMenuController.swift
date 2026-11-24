import AppKit
import MenuBarPluginKit
import ServiceManagement

/// Master framework menu controller providing conditional puzzle-icon visibility,
/// the "Manage Icons ▸" submenu for active plugins, per-plugin rules, and host settings.
final class HostMenuController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu: NSMenu
    private let manager: PluginManager

    init(manager: PluginManager) {
        self.manager = manager
        self.menu = NSMenu(title: "MenuBarPlugins")
        super.init()

        menu.delegate = self
        menu.autoenablesItems = false

        manager.onStateChanged = { [weak self] in
            self?.updateStatusItemVisibility()
        }
        manager.makeManageMenuItem = { [weak self] in
            self?.makeManageIconsMenuItem() ?? NSMenuItem()
        }

        updateStatusItemVisibility()
    }

    deinit {
        if let existing = statusItem {
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    /// Shows the puzzle icon iff `persistentIcon` is ON and 0 plugin icons are currently active.
    func updateStatusItemVisibility() {
        let shouldShow = manager.persistentIcon && manager.activePluginCount == 0

        if shouldShow {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            if let button = item.button {
                let img = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "MenuBarPlugins")
                img?.isTemplate = true
                button.image = img
                button.toolTip = "MenuBarPlugins"
            }
            item.menu = menu
            statusItem = item
        } else if let existing = statusItem {
            menu.removeAllItems()
            NSStatusBar.system.removeStatusItem(existing)
            statusItem = nil
        }
    }

    /// Builds a lazy "Manage Icons ▸" submenu item embedded at the bottom of active plugin menus.
    func makeManageIconsMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Manage Icons", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "puzzlepiece.extension", accessibilityDescription: "Manage Icons")
        let sub = NSMenu(title: "Manage Icons")
        sub.delegate = self
        sub.autoenablesItems = false
        item.submenu = sub
        return item
    }

    // MARK: - NSMenuDelegate (Lazy Menu Construction)

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateManagementMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        menu.removeAllItems()
    }

    private func populateManagementMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "MenuBarPlugins", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let summaries = manager.summaries()
        if summaries.isEmpty {
            let empty = NSMenuItem(title: "No plugins found in Plugins/", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for summary in summaries {
                menu.addItem(makePluginSubmenuItem(for: summary))
            }
        }

        menu.addItem(.separator())

        menu.addItem(makeActionItem(title: "Reload Plugins", symbol: "arrow.clockwise") { [weak self] in
            self?.manager.reloadAll()
        })

        menu.addItem(makeActionItem(title: "Open Plugins Folder", symbol: "folder") { [weak self] in
            guard let url = self?.manager.pluginsDirectoryURL else { return }
            NSWorkspace.shared.open(url)
        })

        menu.addItem(makeActionItem(title: "Choose Plugins Folder…", symbol: "folder.badge.gearshape") { [weak self] in
            self?.choosePluginsFolder()
        })

        menu.addItem(makeActionItem(title: "Open config.json", symbol: "doc.text") { [weak self] in
            guard let self else { return }
            self.manager.configStore.save()
            NSWorkspace.shared.open(self.manager.configFileURL)
        })

        menu.addItem(.separator())
        menu.addItem(makeSettingsSubmenuItem())

        menu.addItem(makeActionItem(title: "Quit MenuBarPlugins", symbol: "power", keyEquivalent: "q") {
            NSApp.terminate(nil)
        })
    }

    // MARK: - Settings Submenu

    private func makeSettingsSubmenuItem() -> NSMenuItem {
        let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")

        let sub = NSMenu(title: "Settings")
        sub.autoenablesItems = false

        let isPersistent = manager.persistentIcon
        sub.addItem(makeActionItem(title: "Persistent Icon", checked: isPersistent) { [weak self] in
            guard let self else { return }
            self.manager.setPersistentIcon(!self.manager.persistentIcon)
        })

        let isLoginEnabled = SMAppService.mainApp.status == .enabled
        sub.addItem(makeActionItem(title: "Launch at Login", checked: isLoginEnabled) { [weak self] in
            self?.toggleLaunchAtLogin()
        })

        settingsItem.submenu = sub
        return settingsItem
    }

    // MARK: - Per-Plugin Submenu

    private func makePluginSubmenuItem(for summary: PluginSummary) -> NSMenuItem {
        let statusTag: String
        if summary.loadError != nil {
            statusTag = " (Error)"
        } else if !summary.isEnabled {
            statusTag = " (Off)"
        } else if summary.isActive {
            statusTag = ""
        } else {
            statusTag = " (Waiting)"
        }

        let parent = NSMenuItem(title: "\(summary.name)\(statusTag)", action: nil, keyEquivalent: "")
        parent.state = summary.isEnabled ? .on : .off

        let sub = NSMenu(title: summary.name)
        sub.autoenablesItems = false

        // Enable / Disable toggle
        let enableItem = makeActionItem(title: "Enabled", checked: summary.isEnabled) { [weak self] in
            self?.manager.setEnabled(!summary.isEnabled, for: summary.id)
        }
        sub.addItem(enableItem)

        if let err = summary.loadError {
            let errItem = NSMenuItem(title: "Error: \(err)", action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            sub.addItem(errItem)
        }

        sub.addItem(.separator())

        // Activation rule header
        let ruleHeader = NSMenuItem(title: "Activation: \(describe(rule: summary.effectiveRule))", action: nil, keyEquivalent: "")
        ruleHeader.isEnabled = false
        sub.addItem(ruleHeader)

        // Always
        let isAlways = summary.effectiveRule.mode == .always
        sub.addItem(makeActionItem(title: "Always", checked: isAlways) { [weak self] in
            self?.manager.setActivationOverride(.always, for: summary.id)
        })

        // Quick rules for the user's current / last focused app
        if let app = manager.appMonitor.lastExternalApp {
            let runningRule = ActivationRule(mode: .whenAppRunning, bundleIdentifiers: [app.bundleIdentifier])
            sub.addItem(makeActionItem(
                title: "Only when \(app.localizedName) is running",
                checked: summary.effectiveRule == runningRule
            ) { [weak self] in
                self?.manager.setActivationOverride(runningRule, for: summary.id)
            })

            let activeRule = ActivationRule(mode: .whenAppActive, bundleIdentifiers: [app.bundleIdentifier])
            sub.addItem(makeActionItem(
                title: "Only when \(app.localizedName) is active",
                checked: summary.effectiveRule == activeRule
            ) { [weak self] in
                self?.manager.setActivationOverride(activeRule, for: summary.id)
            })
        }

        if summary.hasUserRuleOverride {
            sub.addItem(makeActionItem(title: "Reset to Plugin Default") { [weak self] in
                self?.manager.setActivationOverride(nil, for: summary.id)
            })
        }

        sub.addItem(.separator())

        sub.addItem(makeActionItem(title: "Reveal Plugin Folder", symbol: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([summary.directoryURL])
        })

        parent.submenu = sub
        return parent
    }

    private func describe(rule: ActivationRule) -> String {
        switch rule.mode {
        case .always:
            return "Always"
        case .whenAppRunning:
            let apps = rule.bundleIdentifiers.joined(separator: ", ")
            return "When running (\(apps))"
        case .whenAppActive:
            let apps = rule.bundleIdentifiers.joined(separator: ", ")
            return "When active (\(apps))"
        }
    }

    private func choosePluginsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Plugins Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = manager.pluginsDirectoryURL

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let selected = panel.url {
            manager.setCustomPluginsDirectory(selected)
        }
    }

    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            fputs("[MenuBarHost] Launch at Login toggle failed: \(error.localizedDescription)\n", stderr)
            let alert = NSAlert()
            alert.messageText = "Could not update Launch at Login"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can also add MenuBarPlugins.app in System Settings → General → Login Items."
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func makeActionItem(
        title: String,
        symbol: String? = nil,
        keyEquivalent: String = "",
        checked: Bool = false,
        handler: @escaping () -> Void
    ) -> NSMenuItem {
        let trampoline = MenuActionTrampoline(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTrampoline.invoke), keyEquivalent: keyEquivalent)
        item.target = trampoline
        item.representedObject = trampoline
        item.state = checked ? .on : .off
        if let symbol {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        return item
    }
}
