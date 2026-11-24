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
      mbp list [--plugins-dir <dir>]          List installed plugins in Plugins/
    """
    print(text)
}

func flagValue(_ flag: String, in args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func defaultPluginsDir(from args: [String]) -> URL {
    if let explicit = flagValue("--plugins-dir", in: args) {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
    }
    if let env = ProcessInfo.processInfo.environment["MBP_PLUGINS_DIR"], !env.isEmpty {
        return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Plugins", isDirectory: true)
}

func resolveSDKDir(from args: [String]) -> URL? {
    let fm = FileManager.default
    if let explicit = flagValue("--sdk-dir", in: args) {
        return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
    }
    let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    let candidates = [
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

func sanitizeIdentifier(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    return String(cleaned).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

func cmdNew(_ args: [String]) throws {
    guard args.count >= 1 else {
        fputs("Error: Missing <PluginName>.\n", stderr)
        printUsage()
        exit(1)
    }
    let rawName = args[0]
    let className = rawName.replacingOccurrences(of: " ", with: "") + "Plugin"
    let libName = "lib\(rawName.replacingOccurrences(of: " ", with: "")).dylib"
    let baseDir = args.count >= 2
        ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath, isDirectory: true)
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

    @_cdecl("mbp_create_plugin")
    public func createPlugin() -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(\(className)()).toOpaque()
    }
    """

    let swiftFile = sourcesDir.appendingPathComponent("\(className).swift")
    try swiftSource.write(to: swiftFile, atomically: true, encoding: .utf8)

    print("Created starter plugin at: \(pluginDir.path)")
    print("Next steps:")
    print("  mbp build \"\(pluginDir.path)\"")
    print("  mbp install \"\(pluginDir.path)\"")
}

func cmdBuild(_ args: [String]) throws {
    guard args.count >= 1 else {
        fputs("Error: Missing <PluginDir>.\n", stderr)
        exit(1)
    }
    let pluginDir = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath, isDirectory: true)
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
    guard args.count >= 1 else {
        fputs("Error: Missing <PluginDir>.\n", stderr)
        exit(1)
    }
    let srcDir = URL(fileURLWithPath: (args[0] as NSString).expandingTildeInPath, isDirectory: true)
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

    print("Installed self-contained plugin to: \(destDir.path)")
}

func cmdList(_ args: [String]) throws {
    let pluginsDir = defaultPluginsDir(from: args)
    let fm = FileManager.default
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
            let rule = m.activation?.mode.rawValue ?? "always"
            print("• \(m.name) (\(m.id)) v\(m.version) [\(rule)] — \(dir.lastPathComponent)/")
            count += 1
        } catch {
            print("! \(dir.lastPathComponent)/ — invalid manifest: \(error.localizedDescription)")
        }
    }

    if count == 0 {
        print("No plugins found in \(pluginsDir.path)")
    }
}

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
    case "-h", "--help", "help":
        printUsage()
    default:
        fputs("Unknown command: \(command)\n", stderr)
        printUsage()
        exit(1)
    }
} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
