import AppKit
import Darwin
import Foundation
import MenuBarPluginKit

var passed = 0
var failed = 0

func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: expected \(b), got \(a). \(message)\n", stderr)
    }
}

// 1. Manifest decoding & validation
do {
    let json = """
    {
      "id": "com.test.demo",
      "name": "Demo Plugin",
      "version": "1.2.3",
      "executable": "libDemo.dylib",
      "author": "Tester",
      "activation": {
        "mode": "whenAppActive",
        "bundleIdentifiers": ["com.apple.Safari"]
      }
    }
    """
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("manifest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    try Data(json.utf8).write(to: tempURL)
    let manifest = try PluginManifest.load(from: tempURL)
    assertEqual(manifest.id, "com.test.demo")
    assertEqual(manifest.name, "Demo Plugin")
    assertEqual(manifest.version, "1.2.3")
    assertEqual(manifest.executable, "libDemo.dylib")
    assertEqual(manifest.activation?.mode, .whenAppActive)
    assertEqual(manifest.activation?.bundleIdentifiers, ["com.apple.Safari"])
} catch {
    failed += 1
    fputs("FAIL: Manifest valid decode threw: \(error)\n", stderr)
}

// 2. Manifest rejects empty fields & path traversal
do {
    let emptyID = PluginManifest(id: "  ", name: "Name", version: "1.0", executable: "libX.dylib")
    do {
        try emptyID.validate()
        failed += 1
        fputs("FAIL: Expected emptyID.validate() to throw\n", stderr)
    } catch let err as PluginManifest.ValidationError {
        assertEqual(err, .emptyField("id"))
    } catch {
        failed += 1
        fputs("FAIL: Unexpected error: \(error)\n", stderr)
    }

    let traversal = PluginManifest(id: "com.test.bad", name: "Bad", version: "1.0", executable: "../evil.dylib")
    do {
        try traversal.validate()
        failed += 1
        fputs("FAIL: Expected traversal.validate() to throw\n", stderr)
    } catch let err as PluginManifest.ValidationError {
        assertEqual(err, .invalidExecutablePath("../evil.dylib"))
    } catch {
        failed += 1
        fputs("FAIL: Unexpected error: \(error)\n", stderr)
    }
}

// 3. Activation rules
do {
    assertTrue(ActivationRule.always.isSatisfied(runningBundleIDs: [], activeBundleID: nil), "always should match empty")

    let runningRule = ActivationRule(mode: .whenAppRunning, bundleIdentifiers: ["com.apple.Safari", "com.apple.Xcode"])
    assertTrue(!runningRule.isSatisfied(runningBundleIDs: ["com.apple.Finder"], activeBundleID: "com.apple.Finder"), "whenAppRunning false")
    assertTrue(runningRule.isSatisfied(runningBundleIDs: ["com.apple.Finder", "com.apple.Safari"], activeBundleID: "com.apple.Finder"), "whenAppRunning true")

    let activeRule = ActivationRule(mode: .whenAppActive, bundleIdentifiers: ["com.apple.Safari"])
    assertTrue(!activeRule.isSatisfied(runningBundleIDs: ["com.apple.Safari"], activeBundleID: "com.apple.Finder"), "whenAppActive false when background")
    assertTrue(activeRule.isSatisfied(runningBundleIDs: ["com.apple.Safari"], activeBundleID: "com.apple.Safari"), "whenAppActive true when frontmost")
    assertTrue(!activeRule.isSatisfied(runningBundleIDs: ["com.apple.Safari"], activeBundleID: nil), "whenAppActive false when nil")
}

// 4. Scheduler fire, pause, resume, cancel
do {
    let scheduler = PluginScheduler(label: "com.test.scheduler")
    var fired = false
    let token = scheduler.scheduleRepeating(interval: 0.5, leeway: 0.05, fireImmediately: true) {
        fired = true
    }
    assertEqual(scheduler.activeTimerCount, 1)

    let deadline = Date().addingTimeInterval(1.0)
    while !fired && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    assertTrue(fired, "Scheduler timer should fire")

    scheduler.pauseAll()
    assertTrue(scheduler.paused, "Scheduler should be paused")
    scheduler.resumeAll()
    assertTrue(!scheduler.paused, "Scheduler should be resumed")

    token.cancel()
    assertEqual(scheduler.activeTimerCount, 0)
}

// 5. HostConfigFile defaults & round-trip persistence
do {
    // Legacy config.json without `persistentIcon` should default to `true`.
    let legacyJSON = """
    {
      "plugins": {
        "com.example.demo": {
          "enabled": false
        }
      }
    }
    """
    let legacy = try JSONDecoder().decode(HostConfigFile.self, from: Data(legacyJSON.utf8))
    assertTrue(legacy.persistentIcon, "Legacy config without persistentIcon should default to true")
    assertEqual(legacy.plugins["com.example.demo"]?.enabled, false)

    // Round-trip with persistentIcon = false and activationOverride
    let original = HostConfigFile(
        customPluginsDirectory: "/tmp/custom-plugins",
        persistentIcon: false,
        plugins: [
            "com.example.demo": PluginUserConfig(
                enabled: true,
                activationOverride: ActivationRule(mode: .whenAppActive, bundleIdentifiers: ["com.apple.Safari"])
            )
        ]
    )
    let encoded = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(HostConfigFile.self, from: encoded)
    assertEqual(decoded, original, "HostConfigFile should round-trip cleanly")
    assertTrue(!decoded.persistentIcon, "persistentIcon should persist false")
} catch {
    failed += 1
    fputs("FAIL: HostConfigFile test threw: \(error)\n", stderr)
}

// 6. Plugin contract & dynamic dlopen test (FixturePlugin)
if CommandLine.arguments.count >= 2 {
    let fixturePath = CommandLine.arguments[1]
    let tempPluginDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("mbp-fixture-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempPluginDir) }

    do {
        try FileManager.default.createDirectory(at: tempPluginDir, withIntermediateDirectories: true)
        let handle = dlopen(fixturePath, RTLD_NOW | RTLD_LOCAL)
        assertTrue(handle != nil, "dlopen should succeed for FixturePlugin at \(fixturePath)")

        if let handle {
            // Check API version symbol
            let versionSym = dlsym(handle, kMenuBarPluginAPIVersionSymbol)
            assertTrue(versionSym != nil, "FixturePlugin should export \(kMenuBarPluginAPIVersionSymbol)")
            if let versionSym {
                typealias VersionFn = @convention(c) () -> Int32
                let versionFn = unsafeBitCast(versionSym, to: VersionFn.self)
                assertEqual(versionFn(), kMenuBarPluginAPIVersion, "FixturePlugin API version should match SDK")
            }

            // Instantiate via factory symbol
            let sym = dlsym(handle, kMenuBarPluginFactorySymbol)
            assertTrue(sym != nil, "FixturePlugin should export \(kMenuBarPluginFactorySymbol)")
            if let sym {
                typealias Factory = @convention(c) () -> UnsafeMutableRawPointer
                let factory = unsafeBitCast(sym, to: Factory.self)
                let obj = Unmanaged<AnyObject>.fromOpaque(factory()).takeRetainedValue()
                let plugin = obj as? MenuBarPlugin
                assertTrue(plugin != nil, "Factory should return a MenuBarPlugin")
                assertEqual(plugin?.identifier ?? "", "com.test.fixture")

                let scheduler = PluginScheduler(label: "com.test.fixture.scheduler")
                var lastTitle: String?
                var lastSymbol: String?
                var lastImage: NSImage?
                var lastTooltip: String?
                var closedPopover = false

                let ctx = PluginContext(
                    pluginID: "com.test.fixture",
                    pluginDirectoryURL: tempPluginDir,
                    scheduler: scheduler,
                    onSetTitle: { lastTitle = $0 },
                    onSetSymbol: { sym, _ in lastSymbol = sym },
                    onSetImage: { lastImage = $0 },
                    onSetTooltip: { lastTooltip = $0 },
                    onClosePopover: { closedPopover = true }
                )

                plugin?.activate(context: ctx)
                assertEqual(lastTitle, "Fixture")
                assertEqual(lastSymbol, "checkmark.circle")
                assertTrue(lastImage != nil, "setImage callback should receive NSImage")
                assertEqual(lastTooltip, "Fixture Tooltip")
                assertTrue(FileManager.default.fileExists(atPath: ctx.dataDirectoryURL.path), "ensureDataDirectory should create Data/")
                assertEqual(scheduler.activeTimerCount, 1, "scheduleRepeating should register 1 timer")

                let menu = plugin?.buildMenu?() ?? []
                assertEqual(menu.count, 4, "buildMenu should return label, separator, action, submenu")
                menu[2].action?()
                assertEqual(lastTitle, "Pong", "Menu action closure should update title")
                menu[3].children.first?.action?()
                assertEqual(lastTooltip, "Nested", "Submenu action closure should update tooltip")

                assertTrue(plugin?.makePopoverViewController?() != nil, "makePopoverViewController should return NSViewController")
                assertEqual(plugin?.preferredPopoverSize?(), NSSize(width: 240, height: 160))

                plugin?.deactivate()
                assertTrue(closedPopover, "deactivate should call closePopover")
                assertEqual(scheduler.activeTimerCount, 0, "deactivate should cancel all timers")
            }
        }
    } catch {
        failed += 1
        fputs("FAIL: FixturePlugin contract test threw: \(error)\n", stderr)
    }
}

print("Tests finished: \(passed) passed, \(failed) failed.")
exit(failed == 0 ? 0 : 1)
