import Foundation

/// Lightweight, declarative menu item model converted into `NSMenuItem` lazily on click.
@objcMembers
public final class MenuItemModel: NSObject {
    public enum Kind {
        case item
        case separator
        case submenu
    }

    public let kind: Kind
    public let title: String
    public let symbolName: String?
    public let keyEquivalent: String
    public let isEnabled: Bool
    public let isChecked: Bool
    public let action: (() -> Void)?
    public let children: [MenuItemModel]

    private init(
        kind: Kind,
        title: String = "",
        symbolName: String? = nil,
        keyEquivalent: String = "",
        isEnabled: Bool = true,
        isChecked: Bool = false,
        action: (() -> Void)? = nil,
        children: [MenuItemModel] = []
    ) {
        self.kind = kind
        self.title = title
        self.symbolName = symbolName
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
        self.isChecked = isChecked
        self.action = action
        self.children = children
    }

    /// A non-interactive informational label.
    public static func label(_ title: String, symbolName: String? = nil) -> MenuItemModel {
        MenuItemModel(kind: .item, title: title, symbolName: symbolName, isEnabled: false)
    }

    /// A clickable menu action.
    public static func action(
        _ title: String,
        symbolName: String? = nil,
        keyEquivalent: String = "",
        isChecked: Bool = false,
        isEnabled: Bool = true,
        handler: @escaping () -> Void
    ) -> MenuItemModel {
        MenuItemModel(
            kind: .item,
            title: title,
            symbolName: symbolName,
            keyEquivalent: keyEquivalent,
            isEnabled: isEnabled,
            isChecked: isChecked,
            action: handler
        )
    }

    /// A horizontal divider line.
    public static func separator() -> MenuItemModel {
        MenuItemModel(kind: .separator)
    }

    /// A nested submenu.
    public static func submenu(
        _ title: String,
        symbolName: String? = nil,
        items: [MenuItemModel]
    ) -> MenuItemModel {
        MenuItemModel(kind: .submenu, title: title, symbolName: symbolName, children: items)
    }
}
