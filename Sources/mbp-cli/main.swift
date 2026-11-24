import Foundation
import MenuBarPluginKit

func printUsage() {
    let text = """
    mbp — MenuBarPlugins CLI helper

    Usage:
      mbp new <PluginName> [directory]        Scaffold a new starter plugin
      mbp build <PluginDir> [--sdk-dir <dir>] Compile a plugin's Swift sources into a .dylib
      mbp install <PluginDir> [--plugins-dir <dir>]
                                              Install a self-contained plugin folder into Plugins/
      mbp list [--plugins-dir <dir>]          List installed plugins and host settings
      mbp <plugin> enable                     Enable a plugin (by ID, name, or folder)
      mbp <plugin> disable                    Disable a plugin (by ID, name, or folder)
      mbp <plugin> rule always                Always active when enabled
      mbp <plugin> rule running <bundleID...> Active only while any listed app is running
      mbp <plugin> rule active <bundleID...>  Active only while any listed app is focused
      mbp <plugin> rule default               Reset to the plugin's manifest default rule
      mbp persistent-icon [on|off]            Show or set fallback puzzle icon (default: on)
      mbp reload                              Ask running MenuBarPlugins.app to reload Plugins/
      mbp quit                                Ask running MenuBarPlugins.app to quit
    """
    print(text)
}

func flagValue(_ flag: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func stripFlags(_ args: [String], valuedFlags: Set<String> = ["--plugins-dir", "--config", "--sdk-dir"]) -> [String] {
    var result: [String] = []
    var i = 0
    while i < args.count {
        if valuedFlags.contains(args[i]) {
            i += 2
            continue
        }
        result.append(args[i])
        i += 1
    }
    return result
}

/// Resolves the portable MenuBarPlugins root directory.
/// When `mbp` is symlinked into PATH (e.g. ~/.local/bin/mbp -> <Root>/mbp), resolves through the symlink.
func resolvePortableRoot() -> URL {
    let fm = FileManager.default
    if let execURL = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        let execDir = execURL.deletingLastPathComponent()
        let appURL = execDir.appendingPathComponent("MenuBarPlugins.app", isDirectory: true)
        if fm.fileExists(atPath: appURL.path) {
            return execDir
        }
    }
    return URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
}

func resolveConfigURL(from args: [String]) -> URL {
    if let explicit = flagValue("--config", in: args) {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: false)
    }
    return resolvePortableRoot().appendingPathComponent("config.json", isDirectory: false)
}

func loadHostConfig(at url: URL) -> HostConfigFile {
    if let data = try? Data(contentsOf: url),
       let decoded = try? JSONDecoder().decode(HostConfigFile.self, from: data) {
        return decoded
    }
    return HostConfigFile()
}

func saveHostConfig(_ config: HostConfigFile, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    try data.write(to: url, options: .atomic)
}

func postHostNotification(_ name: Notification.Name) {
    DistributedNotificationCenter.default().postNotificationName(
        name,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

func defaultPluginsDir(from args: [String], config: HostConfigFile? = nil) -> URL {
    if let explicit = flagValue("--plugins-dir", in: args) {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
    }
    if let env = ProcessInfo.processInfo.environment["MBP_PLUGINS_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
    }
    let cfg = config ?? loadHostConfig(at: resolveConfigURL(from: args))
    if let custom = cfg.customPluginsDirectory, !custom.isEmpty {
        return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
    }
    return resolvePortableRoot().appendingPathComponent("Plugins", isDirectory: true)
}

func resolveSDKDir(from args: [String]) -> URL? {
    let fm = FileManager.default
    if let explicit = flagValue("--sdk-dir", in: args) {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
    }
    let root = resolvePortableRoot()
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    let candidates = [
        root.appendingPathComponent("MenuBarPlugins.app/Contents/Frameworks", isDirectory: true),
        cwd.appendingPathComponent("MenuBarPlugins.app/Contents/Frameworks", isDirectory: true)
    ]
    for dir in candidates {
        let dylib = dir.appendingPathComponent("libMenuBarPluginKit.dylib")
        if fm.fileExists(atPath: dylib.path) {
            return dir
        }
    }
    return nil
}

struct InstalledPluginInfo {
    let manifest: PluginManifest
    let folderName: String
}

func discoverInstalledPlugins(in pluginsDir: URL) -> [InstalledPluginInfo] {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(
        at: pluginsDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }

    var results: [InstalledPluginInfo] = []
    for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { continue }
        if let manifest = try? PluginManifest.load(from: manifestURL) {
            results.append(InstalledPluginInfo(manifest: manifest, folderName: dir.lastPathComponent))
        }
    }
    return results
}

func resolvePluginIdentifier(_ query: String, in pluginsDir: URL) -> (id: String, displayName: String) {
    let installed = discoverInstalledPlugins(in: pluginsDir)
    let lowered = query.lowercased()

    if let match = installed.first(where: { $0.manifest.id == query }) {
        return (match.manifest.id, match.manifest.name)
    }
    if let match = installed.first(where: { $0.folderName.lowercased() == lowered }) {
        return (match.manifest.id, match.manifest.name)
    }
    if let match = installed.first(where: { $0.manifest.name.lowercased() == lowered }) {
        return (match.manifest.id, match.manifest.name)
    }

    // Allow targeting a plugin ID directly even if not currently installed in Plugins/
    if query.contains(".") {
        return (query, query)
    }

    fputs("Error: Plugin '\(query)' not found in \(pluginsDir.path).\n", stderr)
    exit(1)
}

func describeRule(_ rule: ActivationRule) -> String {
    switch rule.mode {
    case .always:
        return "always"
    case .whenAppRunning:
        return "running(\(rule.bundleIdentifiers.joined(separator: ", ")))"
    case .whenAppActive:
        return "active(\(rule.bundleIdentifiers.joined(separator: ", ")))"
    @unknown default:
        return "custom"
    }
}

func sanitizeIdentifier(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    return String(cleaned).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

// MARK: - Subcommands

func cmdNew(_ args: [String]) throws {
    let positional = stripFlags(args)
    guard positional.count >= 1 else {
        fputs("Error: Missing <PluginName>.\n", stderr)
        printUsage()
        exit(1)
    }
    let rawName = positional[0]
    let className = rawName.replacingOccurrences(of: " ", with: "") + "Plugin"
    let libName = "lib\(rawName.replacingOccurrences(of: " ", with: "")).dylib"
    let baseDir = positional.count >= 2
        ? URL(fileURLWithPath: (positional[1] as NSString).expandingTildeInPath, isDirectory: true)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let pluginDir = baseDir.appendingPathComponent(rawName, isDirectory: true)
    let sourcesDir = pluginDir.appendingPathComponent("Sources", isDirectory: true)

    try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

    let manifest = PluginManifest(
        id: "com.local.\(sanitizeIdentifier(rawName))",
        name: rawName,
        version: "0.1.0",
        executable: libName,
        author: NSUserName(),
        description: "\(rawName) menu bar plugin",
        activation: .always
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let manifestData = try encoder.encode(manifest)
    try manifestData.write(to: pluginDir.appendingPathComponent("manifest.json"))

    let swiftSource = """
    import AppKit
    import Foundation
    import MenuBarPluginKit

    final class \(className): NSObject, MenuBarPlugin {
        let identifier = "\(manifest.id)"
        private var context: PluginContext?

        func activate(context: PluginContext) {
            self.context = context
            context.setTitle("\(rawName)")
            context.setTooltip("\(rawName)")
        }

        func deactivate() {
            context = nil
        }

        func buildMenu() -> [MenuItemModel] {
            [
                .label("\(rawName) is running"),
                .separator(),
                .action("Ping") { [weak self] in
                    self?.context?.setTitle("\(rawName) ✓")
                }
            ]
        }
    }

    @_cdecl("mbp_plugin_api_version")
    public func pluginAPIVersion() -> Int32 {
        kMenuBarPluginAPIVersion
    }

    @_cdecl("mbp_create_plugin")
    public func createPlugin() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(\(className)()).toOpaque()
    }
    """

    let swiftFile = sourcesDir.appendingPathComponent("\(className).swift")
    try swiftSource.write(to: swiftFile, atomically: true, encoding: .utf8)

    let gitignoreContent = """
    # Compiled build & install artifacts (never commit .dylib binaries)
    *.dylib
    *.dSYM/
    *.swiftmodule
    *.swiftinterface
    *.swiftdoc
    *.swiftsourceinfo

    # Runtime plugin state
    Data/

    # macOS
    .DS_Store
    """
    try gitignoreContent.write(
        to: pluginDir.appendingPathComponent(".gitignore"),
        atomically: true,
        encoding: .utf8
    )

    print("Created starter plugin at: \(pluginDir.path)")
    print("Next steps:")
    print("  mbp build \"\(pluginDir.path)\"")
    print("  mbp install \"\(pluginDir.path)\"")
}

func cmdBuild(_ args: [String]) throws {
    let positional = stripFlags(args)
    guard positional.count >= 1 else {
        fputs("Error: Missing <PluginDir>.\n", stderr)
        exit(1)
    }
    let pluginDir = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath, isDirectory: true)
    let manifestURL = pluginDir.appendingPathComponent("manifest.json")
    let manifest = try PluginManifest.load(from: manifestURL)

    guard let sdkDir = resolveSDKDir(from: args) else {
        fputs("Error: Could not find libMenuBarPluginKit.dylib. Run `./scripts/build-app.sh` first, or pass --sdk-dir.\n", stderr)
        exit(1)
    }

    let sourcesDir = pluginDir.appendingPathComponent("Sources", isDirectory: true)
    let fm = FileManager.default
    let swiftFiles = (try fm.contentsOfDirectory(at: sourcesDir, includingPropertiesForKeys: nil))
        .filter { $0.pathExtension == "swift" }
        .map(\.path)
        .sorted()

    guard !swiftFiles.isEmpty else {
        fputs("Error: No .swift files found in \(sourcesDir.path)\n", stderr)
        exit(1)
    }

    let outputDylib = pluginDir.appendingPathComponent(manifest.executable)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
    process.arguments = [
        "-emit-library",
        "-O",
        "-parse-as-library",
        "-module-cache-path", "/tmp/mbp-module-cache",
        "-I", sdkDir.path,
        "-L", sdkDir.path,
        "-lMenuBarPluginKit",
        "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", sdkDir.path,
        "-o", outputDylib.path
    ] + swiftFiles

    try process.run()
    process.waitUntilExit()

    if process.terminationStatus != 0 {
        fputs("Error: swiftc exited with status \(process.terminationStatus)\n", stderr)
        exit(process.terminationStatus)
    }

    print("Built \(outputDylib.path)")
}

func cmdInstall(_ args: [String]) throws {
    let positional = stripFlags(args)
    guard positional.count >= 1 else {
        fputs("Error: Missing <PluginDir>.\n", stderr)
        exit(1)
    }
    let srcDir = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath, isDirectory: true)
    let manifestURL = srcDir.appendingPathComponent("manifest.json")
    let manifest = try PluginManifest.load(from: manifestURL)
    let dylibURL = srcDir.appendingPathComponent(manifest.executable)

    let fm = FileManager.default
    guard fm.fileExists(atPath: dylibURL.path) else {
        fputs("Error: Compiled library not found at \(dylibURL.path). Run `mbp build` first.\n", stderr)
        exit(1)
    }

    let pluginsDir = defaultPluginsDir(from: args)
    let destDir = pluginsDir.appendingPathComponent(srcDir.lastPathComponent, isDirectory: true)
    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

    let destManifest = destDir.appendingPathComponent("manifest.json")
    let destDylib = destDir.appendingPathComponent(manifest.executable)

    if fm.fileExists(atPath: destManifest.path) { try fm.removeItem(at: destManifest) }
    if fm.fileExists(atPath: destDylib.path) { try fm.removeItem(at: destDylib) }

    try fm.copyItem(at: manifestURL, to: destManifest)
    try fm.copyItem(at: dylibURL, to: destDylib)

    let srcResources = srcDir.appendingPathComponent("Resources", isDirectory: true)
    if fm.fileExists(atPath: srcResources.path) {
        let destResources = destDir.appendingPathComponent("Resources", isDirectory: true)
        if fm.fileExists(atPath: destResources.path) { try fm.removeItem(at: destResources) }
        try fm.copyItem(at: srcResources, to: destResources)
    }

    print("Installed self-contained plugin to: \(destDir.path)")
}

func cmdList(_ args: [String]) throws {
    let configURL = resolveConfigURL(from: args)
    let config = loadHostConfig(at: configURL)
    let pluginsDir = defaultPluginsDir(from: args, config: config)
    let fm = FileManager.default

    print("Persistent icon: \(config.persistentIcon ? "on" : "off")")

    guard let entries = try? fm.contentsOfDirectory(
        at: pluginsDir,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        print("No plugins found in \(pluginsDir.path)")
        return
    }

    var count = 0
    for dir in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifestURL.path) else { continue }
        do {
            let m = try PluginManifest.load(from: manifestURL)
            let userCfg = config.plugins[m.id]
            let enabled = userCfg?.enabled ?? true
            let rule = userCfg?.activationOverride ?? m.activation ?? .always
            let stateLabel = enabled ? "enabled" : "disabled"
            print("• \(m.name) (\(m.id)) v\(m.version) [\(stateLabel), \(describeRule(rule))] — \(dir.lastPathComponent)/")
            count += 1
        } catch {
            print("! \(dir.lastPathComponent)/ — invalid manifest: \(error.localizedDescription)")
        }
    }

    if count == 0 {
        print("No plugins found in \(pluginsDir.path)")
    }
}

func cmdPersistentIcon(_ args: [String]) throws {
    let configURL = resolveConfigURL(from: args)
    var config = loadHostConfig(at: configURL)
    let positional = stripFlags(args)

    guard let value = positional.first?.lowercased() else {
        print("Persistent icon: \(config.persistentIcon ? "on" : "off")")
        return
    }

    switch value {
    case "on", "true", "1", "yes":
        config.persistentIcon = true
    case "off", "false", "0", "no":
        config.persistentIcon = false
    default:
        fputs("Error: Expected 'on' or 'off', got '\(value)'.\n", stderr)
        exit(1)
    }

    try saveHostConfig(config, to: configURL)
    postHostNotification(HostNotification.reloadConfig)
    print("Persistent icon set to: \(config.persistentIcon ? "on" : "off")")
}

func cmdPluginAction(pluginQuery: String, action: String, rest: [String]) throws {
    let configURL = resolveConfigURL(from: rest)
    var config = loadHostConfig(at: configURL)
    let pluginsDir = defaultPluginsDir(from: rest, config: config)
    let resolved = resolvePluginIdentifier(pluginQuery, in: pluginsDir)
    var entry = config.plugins[resolved.id] ?? PluginUserConfig()

    switch action {
    case "enable":
        entry.enabled = true
        config.plugins[resolved.id] = entry
        try saveHostConfig(config, to: configURL)
        postHostNotification(HostNotification.reloadConfig)
        print("Enabled \(resolved.displayName) (\(resolved.id))")

    case "disable":
        entry.enabled = false
        config.plugins[resolved.id] = entry
        try saveHostConfig(config, to: configURL)
        postHostNotification(HostNotification.reloadConfig)
        print("Disabled \(resolved.displayName) (\(resolved.id))")

    case "rule":
        let positional = stripFlags(rest)
        guard let modeArg = positional.first?.lowercased() else {
            let effective = entry.activationOverride ?? .always
            print("\(resolved.displayName) rule: \(describeRule(effective))\(entry.activationOverride == nil ? " (default)" : "")")
            return
        }
        let bundleIDs = Array(positional.dropFirst())
        switch modeArg {
        case "always":
            entry.activationOverride = .always
        case "running":
            guard !bundleIDs.isEmpty else {
                fputs("Error: Specify at least one bundle identifier (e.g. com.apple.Safari).\n", stderr)
                exit(1)
            }
            entry.activationOverride = ActivationRule(mode: .whenAppRunning, bundleIdentifiers: bundleIDs)
        case "active":
            guard !bundleIDs.isEmpty else {
                fputs("Error: Specify at least one bundle identifier (e.g. com.apple.Safari).\n", stderr)
                exit(1)
            }
            entry.activationOverride = ActivationRule(mode: .whenAppActive, bundleIdentifiers: bundleIDs)
        case "default", "reset":
            entry.activationOverride = nil
        default:
            fputs("Error: Unknown rule '\(modeArg)'. Use: always, running <bundleID...>, active <bundleID...>, or default.\n", stderr)
            exit(1)
        }
        config.plugins[resolved.id] = entry
        try saveHostConfig(config, to: configURL)
        postHostNotification(HostNotification.reloadConfig)
        if let override = entry.activationOverride {
            print("Set rule for \(resolved.displayName) (\(resolved.id)): \(describeRule(override))")
        } else {
            print("Reset rule for \(resolved.displayName) (\(resolved.id)) to plugin default")
        }

    default:
        fputs("Error: Unknown plugin action '\(action)'. Use: enable, disable, or rule.\n", stderr)
        printUsage()
        exit(1)
    }
}

// MARK: - Main Dispatch

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first else {
        printUsage()
        exit(0)
    }
    let rest = Array(args.dropFirst())

    switch command {
    case "new":
        try cmdNew(rest)
    case "build":
        try cmdBuild(rest)
    case "install":
        try cmdInstall(rest)
    case "list":
        try cmdList(rest)
    case "persistent-icon":
        try cmdPersistentIcon(rest)
    case "reload":
        postHostNotification(HostNotification.reloadPlugins)
        print("Sent reload notification to MenuBarPlugins.")
    case "quit":
        postHostNotification(HostNotification.quit)
        print("Sent quit notification to MenuBarPlugins.")
    case "-h", "--help", "help":
        printUsage()
    default:
        // Plugin-scoped syntax: mbp <plugin> enable|disable|rule ...
        guard let action = rest.first else {
            fputs("Unknown command: \(command)\n", stderr)
            printUsage()
            exit(1)
        }
        try cmdPluginAction(pluginQuery: command, action: action, rest: Array(rest.dropFirst()))
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
