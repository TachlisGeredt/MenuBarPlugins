import AppKit

/// Zero-polling monitor for running and frontmost macOS applications using `NSWorkspace` push notifications.
final class AppContextMonitor {
    struct AppInfo: Equatable {
        let bundleIdentifier: String
        let localizedName: String
    }

    private(set) var runningBundleIDs: Set<String> = []
    private(set) var activeBundleID: String?
    private(set) var lastExternalApp: AppInfo?

    private let ownBundleID: String?
    private var observers: [NSObjectProtocol] = []
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.ownBundleID = Bundle.main.bundleIdentifier
        self.onChange = onChange

        refreshInitialState()
        registerObservers()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        for token in observers {
            nc.removeObserver(token)
        }
    }

    private func refreshInitialState() {
        let workspace = NSWorkspace.shared
        runningBundleIDs = Set(workspace.runningApplications.compactMap { $0.bundleIdentifier })
        if let front = workspace.frontmostApplication, let bid = front.bundleIdentifier {
            activeBundleID = bid
            if bid != ownBundleID {
                lastExternalApp = AppInfo(
                    bundleIdentifier: bid,
                    localizedName: front.localizedName ?? bid
                )
            }
        }
    }

    private func registerObservers() {
        let nc = NSWorkspace.shared.notificationCenter

        observers.append(
            nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bid = app.bundleIdentifier else { return }
                if self.runningBundleIDs.insert(bid).inserted {
                    self.onChange()
                }
            }
        )

        observers.append(
            nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bid = app.bundleIdentifier else { return }
                let removed = self.runningBundleIDs.remove(bid) != nil
                if self.activeBundleID == bid {
                    self.activeBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                }
                if removed {
                    self.onChange()
                }
            }
        )

        observers.append(
            nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let self,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bid = app.bundleIdentifier else { return }
                self.runningBundleIDs.insert(bid)
                if bid != self.ownBundleID {
                    self.lastExternalApp = AppInfo(
                        bundleIdentifier: bid,
                        localizedName: app.localizedName ?? bid
                    )
                }
                if self.activeBundleID != bid {
                    self.activeBundleID = bid
                    self.onChange()
                }
            }
        )
    }
}
