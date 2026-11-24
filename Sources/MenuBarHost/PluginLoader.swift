import Darwin
import Foundation
import MenuBarPluginKit

/// Represents a discovered self-contained plugin folder inside `Plugins/`.
struct DiscoveredPlugin {
    let manifest: PluginManifest
    let directoryURL: URL
    let executableURL: URL
}

enum PluginLoadError: Error, LocalizedError {
    case missingExecutable(URL)
    case dlopenFailed(String)
    case incompatibleAPIVersion(found: Int32, expected: Int32)
    case missingFactorySymbol(String)
    case invalidPluginInstance(String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let url):
            return "Plugin executable not found at \(url.path)"
        case .dlopenFailed(let message):
            return "Failed to load plugin library: \(message)"
        case .incompatibleAPIVersion(let found, let expected):
            return "Plugin built for API v\(found), but host requires API v\(expected) — please rebuild plugin"
        case .missingFactorySymbol(let symbol):
            return "Plugin does not export required symbol '\(symbol)'"
        case .invalidPluginInstance(let id):
            return "Factory did not return a valid MenuBarPlugin instance for '\(id)'"
        }
    }
}

/// Discovers self-contained plugin folders inside `Plugins/` and loads their `.dylib` binaries via `dlopen`/`dlsym`.
final class PluginLoader {
    private typealias PluginFactoryFn = @convention(c) () -> UnsafeMutableRawPointer
    private typealias PluginAPIVersionFn = @convention(c) () -> Int32

    /// Tracks opened library handles by resolved path.
    /// On macOS, ObjC/Swift dylibs should remain mapped once loaded to avoid ObjC runtime class-unload issues;
    /// deactivating a plugin releases its Swift instance and cancels all timers without unsafe `dlclose`.
    private var openHandles: [String: UnsafeMutableRawPointer] = [:]

    /// Scans `pluginsDirectory` for any subfolder containing a valid `manifest.json`.
    func discoverPlugins(in pluginsDirectory: URL) -> [DiscoveredPlugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: pluginsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [DiscoveredPlugin] = []
        var seenIDs = Set<String>()

        for dirURL in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? dirURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }

            let manifestURL = dirURL.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifestURL.path) else { continue }

            do {
                let manifest = try PluginManifest.load(from: manifestURL)
                guard seenIDs.insert(manifest.id).inserted else {
                    fputs("[MenuBarHost] Skipping duplicate plugin ID '\(manifest.id)' at \(dirURL.path)\n", stderr)
                    continue
                }
                let execURL = dirURL.appendingPathComponent(manifest.executable)
                results.append(DiscoveredPlugin(manifest: manifest, directoryURL: dirURL, executableURL: execURL))
            } catch {
                fputs("[MenuBarHost] Invalid manifest at \(manifestURL.path): \(error.localizedDescription)\n", stderr)
            }
        }

        return results
    }

    /// Instantiates a plugin from its compiled `.dylib`.
    func instantiate(_ discovered: DiscoveredPlugin) throws -> MenuBarPlugin {
        let execPath = discovered.executableURL.resolvingSymlinksInPath().path
        guard FileManager.default.fileExists(atPath: execPath) else {
            throw PluginLoadError.missingExecutable(discovered.executableURL)
        }

        let handle: UnsafeMutableRawPointer
        if let existing = openHandles[execPath] {
            handle = existing
        } else {
            guard let opened = dlopen(execPath, RTLD_NOW | RTLD_LOCAL) else {
                let err = dlerror().map { String(cString: $0) } ?? "unknown error"
                throw PluginLoadError.dlopenFailed(err)
            }
            openHandles[execPath] = opened
            handle = opened
        }

        if let versionSym = dlsym(handle, kMenuBarPluginAPIVersionSymbol) {
            let versionFn = unsafeBitCast(versionSym, to: PluginAPIVersionFn.self)
            let pluginVersion = versionFn()
            if pluginVersion != kMenuBarPluginAPIVersion {
                throw PluginLoadError.incompatibleAPIVersion(found: pluginVersion, expected: kMenuBarPluginAPIVersion)
            }
        }

        guard let sym = dlsym(handle, kMenuBarPluginFactorySymbol) else {
            throw PluginLoadError.missingFactorySymbol(kMenuBarPluginFactorySymbol)
        }

        let factory = unsafeBitCast(sym, to: PluginFactoryFn.self)
        let rawPtr = factory()
        let obj = Unmanaged<AnyObject>.fromOpaque(rawPtr).takeRetainedValue()
        guard let plugin = obj as? MenuBarPlugin else {
            throw PluginLoadError.invalidPluginInstance(discovered.manifest.id)
        }
        return plugin
    }
}
