import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cliPluginsDirectory: String?
    private var pluginManager: PluginManager?
    private var hostMenuController: HostMenuController?

    init(cliPluginsDirectory: String?) {
        self.cliPluginsDirectory = cliPluginsDirectory
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = PluginManager(cliPluginsDirectory: cliPluginsDirectory)
        self.pluginManager = manager
        self.hostMenuController = HostMenuController(manager: manager)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pluginManager?.deactivateAll()
    }
}
