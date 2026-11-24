import AppKit
import MenuBarPluginKit

/// Lightweight target wrapper retained by `NSMenuItem.representedObject` and freed on menu teardown.
final class MenuActionTrampoline: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke() {
        handler()
    }
}

/// Converts declarative `[MenuItemModel]` into AppKit `NSMenuItem`s lazily.
enum MenuBuilder {
    static func populate(_ menu: NSMenu, with models: [MenuItemModel]) {
        menu.removeAllItems()
        for model in models {
            menu.addItem(makeItem(from: model))
        }
    }

    private static func makeItem(from model: MenuItemModel) -> NSMenuItem {
        switch model.kind {
        case .separator:
            return NSMenuItem.separator()

        case .submenu:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            if let symbol = model.symbolName {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.title)
            }
            let sub = NSMenu(title: model.title)
            populate(sub, with: model.children)
            item.submenu = sub
            return item

        case .item:
            let item = NSMenuItem(title: model.title, action: nil, keyEquivalent: model.keyEquivalent)
            item.isEnabled = model.isEnabled
            item.state = model.isChecked ? .on : .off
            if let symbol = model.symbolName {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: model.title)
            }
            if let action = model.action {
                let trampoline = MenuActionTrampoline(action)
                item.target = trampoline
                item.action = #selector(MenuActionTrampoline.invoke)
                item.representedObject = trampoline
            }
            return item
        }
    }
}

/// Manages a single active plugin's `NSStatusItem`, lazy `NSMenu`, and optional lazy `NSPopover`.
final class StatusItemController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private weak var plugin: MenuBarPlugin?
    private let lazyMenu: NSMenu
    private var popover: NSPopover?
    private let supportsPopover: Bool
    private let makeManageMenuItem: (() -> NSMenuItem)?

    init(
        plugin: MenuBarPlugin,
        defaultTitle: String,
        makeManageMenuItem: (() -> NSMenuItem)? = nil
    ) {
        self.plugin = plugin
        self.makeManageMenuItem = makeManageMenuItem
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.lazyMenu = NSMenu()
        self.supportsPopover = (plugin as AnyObject).responds(to: #selector(MenuBarPlugin.makePopoverViewController))
        super.init()

        lazyMenu.delegate = self
        lazyMenu.autoenablesItems = false

        if let button = statusItem.button {
            button.title = defaultTitle
        }

        if supportsPopover {
            if let button = statusItem.button {
                button.target = self
                button.action = #selector(handleStatusButtonClick(_:))
                button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            }
        } else {
            statusItem.menu = lazyMenu
        }
    }

    deinit {
        teardown()
    }

    func teardown() {
        closePopover()
        lazyMenu.removeAllItems()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func setTitle(_ title: String?) {
        statusItem.button?.title = title ?? ""
    }

    func setSymbol(_ symbolName: String?, accessibilityDescription: String?) {
        if let name = symbolName {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
            image?.isTemplate = true
            statusItem.button?.image = image
        } else {
            statusItem.button?.image = nil
        }
    }

    func setTooltip(_ tooltip: String?) {
        statusItem.button?.toolTip = tooltip
    }

    func closePopover() {
        popover?.performClose(nil)
        popover?.contentViewController = nil
        popover = nil
    }

    // MARK: - Popover / Right-Click Handling

    private func populateMenu(_ menu: NSMenu) {
        let items = plugin?.buildMenu?() ?? []
        MenuBuilder.populate(menu, with: items)
        if let makeManageMenuItem {
            if !menu.items.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(makeManageMenuItem())
        }
    }

    private func showPopupMenu() {
        populateMenu(lazyMenu)
        guard !lazyMenu.items.isEmpty else { return }
        statusItem.menu = lazyMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)

        if isRightClick {
            closePopover()
            showPopupMenu()
            return
        }

        togglePopover(relativeTo: sender)
    }

    private func togglePopover(relativeTo button: NSStatusBarButton) {
        if let existing = popover, existing.isShown {
            closePopover()
            return
        }

        guard let vc = plugin?.makePopoverViewController?() else {
            // Plugin returned nil for popover; fall back to menu.
            showPopupMenu()
            return
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.delegate = self
        pop.contentViewController = vc
        if let size = plugin?.preferredPopoverSize?(), size.width > 0, size.height > 0 {
            pop.contentSize = size
        }
        self.popover = pop
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Immediately deallocate plugin's custom view controller so idle RAM stays zero.
        popover?.contentViewController = nil
        popover = nil
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Release menu items & closures when closed.
        menu.removeAllItems()
    }
}
